import Cocoa

/// The answer to **Check for Updates…**, in a small alert-shaped window.
///
/// The menu row used to be the whole answer, but the click that asks also closes the
/// menu, so the answer landed where nobody was looking: the person clicked and saw
/// nothing happen. This window opens on that click and on nothing else — the periodic
/// check and the automatic install never show it (CLAUDE.md rule 2) — follows the
/// check from "Checking…" to its result, and closes on OK, Esc or the close button.
final class UpdatePrompt: NSObject, NSWindowDelegate {
    static let shared = UpdatePrompt()

    /// What the window says for one updater status. Pure, so tests can read every
    /// state without a window.
    struct Content: Equatable {
        enum Action: Equatable { case close, install, whatsNew, retry }
        struct Button: Equatable {
            let title: String
            let action: Action
        }
        var title: String
        var message: String
        var busy: Bool
        /// Leftmost first; the last one is the default (Return).
        var buttons: [Button]
    }

    /// nil for `.idle`: a menu closing clears "Up to date" back to idle, and the
    /// window keeps the answer it already showed rather than going blank.
    static func content(_ s: UpdateChecker.Status, current: String) -> Content? {
        switch s {
        case .idle:
            return nil
        case .checking:
            return Content(title: "Checking for updates…", message: "AgentBar \(current)",
                           busy: true, buttons: [.init(title: "Cancel", action: .close)])
        case .upToDate:
            return Content(title: "You're up to date!",
                           message: "AgentBar \(current) is the newest version available.",
                           busy: false, buttons: [.init(title: "What's New", action: .whatsNew),
                                                  .init(title: "OK", action: .close)])
        case .available(let v):
            return Content(title: "AgentBar \(v) is available",
                           message: "You have \(current). Installing relaunches AgentBar.",
                           busy: false, buttons: [.init(title: "Later", action: .close),
                                                  .init(title: "What's New", action: .whatsNew),
                                                  .init(title: "Install & Relaunch", action: .install)])
        case .downloading(let v):
            return Content(title: "Downloading AgentBar \(v)…",
                           message: "You can close this; the download carries on.",
                           busy: true, buttons: [.init(title: "Hide", action: .close)])
        case .ready(let v):
            return Content(title: "AgentBar \(v) is ready",
                           message: "It installs by itself once nothing is waiting on you "
                               + "and you have been away five minutes.",
                           busy: false, buttons: [.init(title: "Later", action: .close),
                                                  .init(title: "Relaunch Now", action: .install)])
        case .failed(let reason):
            return Content(title: reason,
                           message: "Nothing was changed. Check your connection and try again, "
                               + "or get the latest from github.com/michalstrnadel/AgentBar.",
                           busy: false, buttons: [.init(title: "OK", action: .close),
                                                  .init(title: "Try Again", action: .retry)])
        }
    }

    /// A panel, because a panel closes on Esc by itself.
    private var window: NSPanel?
    private var titleLabel: NSTextField!
    private var messageLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var buttonRow: NSStackView!
    private var observer: NSObjectProtocol?
    private var shown: Content?

    /// The menu rows' click: start a check and show it happening.
    func check() {
        if window == nil { build() }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: UpdateChecker.didChange, object: nil, queue: .main) { [weak self] _ in
                self?.sync()
            }
        }
        UpdateChecker.shared.check(manual: true)
        // A check already in flight (or an update already on offer) does not change
        // the status, so draw what is there now.
        sync()
        if window?.isVisible == false { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func sync() {
        let u = UpdateChecker.shared
        guard let c = Self.content(u.status, current: u.currentVersion), c != shown else { return }
        shown = c
        titleLabel.stringValue = c.title
        messageLabel.stringValue = c.message
        spinner.isHidden = !c.busy
        if c.busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        for b in buttonRow.arrangedSubviews { b.removeFromSuperview() }
        // Two side by side; three do not fit 300 points, so they stack the way
        // macOS stacks an alert's, the default on top.
        let stacked = c.buttons.count > 2
        buttonRow.orientation = stacked ? .vertical : .horizontal
        buttonRow.distribution = stacked ? .fill : .fillEqually
        let ordered = Array(c.buttons.enumerated())
        for (i, spec) in stacked ? ordered.reversed() : ordered {
            let b = NSButton(title: spec.title, target: self, action: #selector(clicked))
            b.tag = i
            b.bezelStyle = .rounded
            b.controlSize = .large
            if i == c.buttons.count - 1 { b.keyEquivalent = "\r" }
            buttonRow.addArrangedSubview(b)
            if stacked { b.widthAnchor.constraint(equalTo: buttonRow.widthAnchor).isActive = true }
        }
        // Each state has its own height; the window follows its content.
        if let w = window, let v = w.contentView {
            v.layoutSubtreeIfNeeded()
            let top = w.frame.maxY
            w.setContentSize(NSSize(width: Self.width, height: v.fittingSize.height))
            if w.isVisible { w.setFrameTopLeftPoint(NSPoint(x: w.frame.minX, y: top)) }
        }
    }

    @objc private func clicked(_ sender: NSButton) {
        guard let c = shown, c.buttons.indices.contains(sender.tag) else { return }
        switch c.buttons[sender.tag].action {
        case .close:
            window?.close()
        case .install:
            UpdateChecker.shared.installAvailable()
        case .whatsNew:
            window?.close()
            SettingsWindow.shared.show(page: .whatsNew)
        case .retry:
            UpdateChecker.shared.check(manual: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        shown = nil
    }

    // MARK: - Build

    private static let width: CGFloat = 300

    private func build() {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 240),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Software Update"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        // An alert, not a document: close is the only traffic light it needs.
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.delegate = self

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        titleLabel = NSTextField(wrappingLabelWithString: "")
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.alignment = .center
        messageLabel = NSTextField(wrappingLabelWithString: "")
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [icon, titleLabel, messageLabel, spinner, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(16, after: spinner)
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.width),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        w.contentView = content
        window = w
    }
}
