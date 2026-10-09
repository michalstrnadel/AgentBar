import Cocoa
import CoreImage

/// Settings ▸ Phone: approvals on the phone, through ntfy (`PhoneRelay`). The one
/// page whose switch sends something off the Mac, so it says what goes where before
/// it says anything else, and it is off until switched on here — nowhere else, and
/// never from a link (CLAUDE.md rule 2). `SettingsWindow` hosts it.
final class PhonePage: NSObject {
    /// Fired after a control wrote a preference.
    var onChange: (() -> Void)?

    private var onBox: NSSwitch!
    private let whenPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var commandBox: NSSwitch!
    private let qr = NSImageView()
    private let topicLabel = NSTextField(labelWithString: "")
    private let serverRow = SettingsChrome.caption("")
    private let testStatus = SettingsChrome.caption(PhonePage.untested)
    private var testButton: NSButton!

    private(set) lazy var views: [NSView] = build()

    private static let untested = "A notification with one button proves the whole path."

    /// The test line changes length at runtime; its row follows what it measures.
    private func say(_ text: String) {
        testStatus.stringValue = text
        testStatus.fittedHeight?.constant = SettingsChrome.measure(
            testStatus, width: SettingsChrome.cardWidth - SettingsChrome.rowInset * 2)
    }

    private func build() -> [NSView] {
        onBox = SettingsChrome.toggle(target: self, action: #selector(toggleOn))
        whenPopup.controlSize = .small
        whenPopup.addItem(withTitle: "When I'm Away")
        whenPopup.lastItem?.representedObject = PhoneRelay.When.away.rawValue
        whenPopup.addItem(withTitle: "Always")
        whenPopup.lastItem?.representedObject = PhoneRelay.When.always.rawValue
        whenPopup.target = self
        whenPopup.action = #selector(whenChanged)
        commandBox = SettingsChrome.toggle(target: self, action: #selector(toggleCommand))

        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.translatesAutoresizingMaskIntoConstraints = false
        qr.widthAnchor.constraint(equalToConstant: 92).isActive = true
        qr.heightAnchor.constraint(equalToConstant: 92).isActive = true
        qr.setAccessibilityLabel("QR code that subscribes the ntfy app to your topic")
        topicLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        topicLabel.isSelectable = true
        topicLabel.lineBreakMode = .byTruncatingMiddle
        let scan = NSTextField(wrappingLabelWithString:
            "Install ntfy on your phone and scan this, or subscribe to the topic below.")
        scan.font = .systemFont(ofSize: 12.5)
        scan.preferredMaxLayoutWidth = 260
        let buttons = NSStackView(views: [
            SettingsChrome.smallButton("Copy Topic", target: self, action: #selector(copyTopic)),
            SettingsChrome.smallButton("New Topic…", target: self, action: #selector(newTopic)),
        ])
        buttons.spacing = SettingsChrome.Space.tight
        let side = NSStackView(views: [scan, topicLabel, buttons])
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = SettingsChrome.Space.tight
        let subscribe = NSStackView(views: [qr, side])
        subscribe.orientation = .horizontal
        subscribe.alignment = .centerY
        subscribe.spacing = SettingsChrome.Space.step

        testButton = SettingsChrome.smallButton("Send a Test", target: self, action: #selector(sendTest))

        return [
            SettingsChrome.header("Answer requests from your phone, through ntfy. What waits on you is "
                                  + "sent to the ntfy server; nothing else ever leaves the Mac."),
            SettingsChrome.card([
                SettingsChrome.row("Send requests to my phone", control: onBox),
                SettingsChrome.row("When", "Away means the screen is locked or untouched for two minutes.",
                                   control: whenPopup),
                SettingsChrome.row("Include the command",
                                   "Allow comes only with a command short enough to read whole. "
                                   + "Off: who waits where, and Deny.", control: commandBox),
            ]),
            SettingsChrome.card([
                SettingsChrome.customRow(subscribe, height: 108),
                SettingsChrome.row("Server", control: SettingsChrome.smallButton(
                    "Change…", target: self, action: #selector(changeServer)),
                                   accessory: serverRow),
                SettingsChrome.row("Try the way there and back", control: testButton),
                SettingsChrome.noteRow(testStatus),
            ]),
            SettingsChrome.caption("Anyone who knows the topic can read what is sent and answer it — "
                                   + "treat it like a password. On iPhone, ntfy shows the buttons "
                                   + "inside its app rather than on the banner."),
        ]
    }

    func reload() {
        _ = views
        onBox.state = PhoneRelay.Prefs.enabled ? .on : .off
        whenPopup.selectItem(at: PhoneRelay.Prefs.when == .away ? 0 : 1)
        commandBox.state = PhoneRelay.Prefs.detail == .full ? .on : .off
        let topic = PhoneRelay.Prefs.topic
        topicLabel.stringValue = topic
        qr.image = Self.qrImage(PhoneRelay.subscribeLink(server: PhoneRelay.Prefs.server, topic: topic))
        let host = PhoneRelay.serverURL(PhoneRelay.Prefs.server)?.host ?? "not set"
        serverRow.stringValue = host + (PhoneRelay.token == nil ? "" : " · with a token")
        for control in [whenPopup, commandBox, testButton] as [NSControl] {
            control.isEnabled = PhoneRelay.Prefs.enabled
        }
    }

    /// A QR code drawn crisp at any size: CoreImage's 1-point modules scaled up
    /// by a whole number, never interpolated.
    static func qrImage(_ text: String) -> NSImage? {
        guard !text.isEmpty, let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Actions

    @objc private func toggleOn() {
        PhoneRelay.Prefs.enabled = onBox.state == .on
        if !PhoneRelay.Prefs.enabled { say(Self.untested) }
        changed()
    }

    @objc private func whenChanged() {
        let raw = whenPopup.selectedItem?.representedObject as? String ?? ""
        PhoneRelay.Prefs.when = PhoneRelay.When(rawValue: raw) ?? .away
        changed()
    }

    @objc private func toggleCommand() {
        PhoneRelay.Prefs.detail = commandBox.state == .on ? .full : .privately
        changed()
    }

    @objc private func copyTopic() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(PhoneRelay.Prefs.topic, forType: .string)
    }

    @objc private func newTopic() {
        let alert = NSAlert()
        alert.messageText = "Start a new topic?"
        alert.informativeText = "Do this if the topic was seen by anyone else. The phone stops "
            + "receiving until you subscribe it to the new one."
        alert.addButton(withTitle: "New Topic")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        PhoneRelay.Prefs.regenerateTopic()
        changed()
    }

    @objc private func changeServer() {
        let alert = NSAlert()
        alert.messageText = "ntfy server"
        alert.informativeText = "https, or http on your own network. A server of your own with an "
            + "access token keeps the topic from being the only key. The token is kept in the Keychain."
        let server = NSTextField(string: PhoneRelay.Prefs.server)
        server.placeholderString = PhoneRelay.defaultServer
        let token = NSSecureTextField(string: "")
        token.placeholderString = PhoneRelay.token == nil ? "Access token (optional)" : "Token saved — type to replace"
        for f in [server, token] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        let stack = NSStackView(views: [server, token])
        stack.orientation = .vertical
        stack.spacing = SettingsChrome.Space.tight
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 52)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if PhoneRelay.token != nil { alert.addButton(withTitle: "Remove Token") }
        alert.window.initialFirstResponder = server
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let typed = server.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = typed.isEmpty ? PhoneRelay.defaultServer : typed
            guard PhoneRelay.serverURL(raw) != nil else {
                say(PhoneRelay.TestError.badServer.localizedDescription)
                return
            }
            PhoneRelay.Prefs.server = raw
            let t = token.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { PhoneRelay.setToken(t) }
        case .alertThirdButtonReturn:
            PhoneRelay.setToken(nil)
        default:
            return
        }
        changed()
    }

    @objc private func sendTest() {
        say("Sent. Tap “Tap to confirm” on the phone…")
        testButton.isEnabled = false
        PhoneRelay.shared.sendTest { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let seconds):
                self.say(String(format: "It works — back in %.0f s.", max(1, seconds)))
            case .failure(let error):
                self.say(error.localizedDescription)
            }
            self.testButton.isEnabled = PhoneRelay.Prefs.enabled
            self.onChange?()
        }
        onChange?()
    }

    private func changed() {
        PhoneRelay.shared.requestsChanged()
        reload()
        onChange?()
    }
}
