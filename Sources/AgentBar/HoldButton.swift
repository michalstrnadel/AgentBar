import Cocoa

/// Allow on the island, made as deliberate as the request is far-reaching. With
/// no hold it is the plain button it always was. With one, it answers only after
/// being held that long — the fill sweeping across says how far along — and
/// letting go early answers nothing at all. Return held in the keyboard queue
/// drives the same clock (`press` / `release`).
///
/// Friction where it is earned, not everywhere: a `git status` is still a click.
/// The point is that `rm -rf` and `curl … | bash` can't be answered by the same
/// reflex that answers forty test runs a day.
final class HoldButton: NSView {
    let hold: TimeInterval
    private let onCommit: () -> Void
    private let title: String
    private let hint: String?

    private let fill = CALayer()
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    /// When the current press began; nil while nobody is holding.
    private(set) var pressedAt: TimeInterval?
    private(set) var committed = false
    private(set) var progress: Double = 0

    init(title: String, hint: String?, hold: TimeInterval, onCommit: @escaping () -> Void) {
        self.hold = hold
        self.onCommit = onCommit
        self.title = title
        self.hint = hint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        fill.backgroundColor = NSColor.black.withAlphaComponent(0.16).cgColor
        fill.anchorPoint = .zero
        layer?.addSublayer(fill)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setLabel(holding: false)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        if hold > 0 {
            toolTip = "Hold to allow — this request reaches further than most"
            setAccessibilityHelp("Press and hold to allow")
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Settings ▸ Approvals: whether far-reaching requests are held at all.
    static let enabledKey = "holdToAllowRisky"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// How long Allow is held for a request with these chips: none when the
    /// setting is off.
    static func duration(for chips: [BlastRadius.Chip]) -> TimeInterval {
        enabled ? BlastRadius.severity(of: chips).hold : 0
    }

    private func setLabel(holding: Bool) {
        let words = hold > 0 ? (holding ? "Keep holding…" : "Hold to \(title)") : title
        let text = NSMutableAttributedString(string: words, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.black,
        ])
        if let hint {
            text.append(NSAttributedString(string: " \(hint)", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.black.withAlphaComponent(0.45),
            ]))
        }
        label.attributedStringValue = text
    }

    // MARK: - The clock

    /// A press begins. A button with no hold answers on release instead, the way
    /// any button does, so a press that slides off it can still be taken back.
    func press(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !committed, pressedAt == nil else { return }
        pressedAt = now
        guard hold > 0 else { return }
        Haptics.started()
        setLabel(holding: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Advances the fill, and answers once the hold is complete.
    func tick(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let start = pressedAt, !committed, hold > 0 else { return }
        progress = min(1, (now - start) / hold)
        drawFill()
        // Compared on the elapsed time, with a hair of slack: 10.6 − 10 is not
        // quite 0.6 in floating point, and a hold that lasted is not to be lost to it.
        if now - start >= hold - 1e-6 { commit() }
    }

    /// The press ends. `inside` is whether it ended over the button. Early, it
    /// answers nothing and the fill drains back.
    func release(inside: Bool = true, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard pressedAt != nil, !committed else { return }
        if hold <= 0 {
            pressedAt = nil
            if inside { commit() }
            return
        }
        tick(at: now)
        guard !committed else { return }
        cancel()
    }

    /// Abandons a hold in progress: the pointer left, or the queue moved on.
    func cancel() {
        timer?.invalidate(); timer = nil
        pressedAt = nil
        progress = 0
        setLabel(holding: false)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        drawFill()
        CATransaction.commit()
    }

    private func commit() {
        committed = true
        timer?.invalidate(); timer = nil
        progress = 1
        drawFill()
        if hold > 0 { Haptics.landed() }
        onCommit()
    }

    private func drawFill() {
        CATransaction.begin()
        if pressedAt != nil { CATransaction.setDisableActions(true) }
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
        CATransaction.commit()
    }

    // MARK: - Pointer

    override func mouseDown(with event: NSEvent) { press() }

    override func mouseDragged(with event: NSEvent) {
        // Sliding off the button is how a press is taken back, held or not.
        let p = convert(event.locationInWindow, from: nil)
        if !bounds.contains(p), pressedAt != nil, hold > 0 { cancel() }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        release(inside: bounds.contains(p))
    }

    /// VoiceOver and Switch Control can't hold; pressing through them is as
    /// deliberate an act as a hold, so it answers.
    override func accessibilityPerformPress() -> Bool {
        guard !committed else { return false }
        commit()
        return true
    }

    /// See IslandButton: the panel never becomes key, so the first click is a
    /// real click rather than an activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        drawFill()
    }
}
