import Cocoa

/// The cup in the island's footer. A click turns Keep Mac Awake on with the last
/// choice, or off; a right-click, a control-click or holding the button opens the
/// list of modes. A plain NSButton runs its own tracking loop on mouse-down, which
/// leaves no clean way to tell a hold from a click, so this is a small view that
/// reads the mouse itself.
final class KeepAwakeButton: NSView {
    static let holdDelay: TimeInterval = 0.45

    var onClick: (() -> Void)?
    var onMenu: ((NSView) -> Void)?

    private let image = NSImageView()
    private var holdTimer: Timer?
    private var heldOpen = false

    init(on: Bool, paused: Bool, toolTip: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 18))
        let symbol = on ? "cup.and.saucer.fill" : "cup.and.saucer"
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        // The break button's palette: quiet white when off, accent when on, and
        // yellow for "on, but paused" so a held-back cup never reads as working.
        image.contentTintColor = paused ? .systemYellow
            : on ? .controlAccentColor : NSColor.white.withAlphaComponent(0.55)
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(equalToConstant: 18),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        self.toolTip = toolTip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Keep Mac awake")
        setAccessibilityValue(on ? "On" : "Off")
        setAccessibilityHelp(toolTip)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Keep awake options…") { [weak self] in
                guard let self else { return false }
                self.onMenu?(self)
                return true
            },
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onMenu?(self)
            return
        }
        heldOpen = false
        holdTimer?.invalidate()
        let t = Timer(timeInterval: Self.holdDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.heldOpen = true
            self.onMenu?(self)
        }
        RunLoop.main.add(t, forMode: .common)
        holdTimer = t
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        holdTimer = nil
        guard !heldOpen, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(self)
    }
}
