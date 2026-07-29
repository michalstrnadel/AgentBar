import Cocoa

/// One-line Allow / Always / Deny button strip rendered inside a menu item
/// (NSMenuItem.view), so a pending approval is answerable without a submenu.
final class ApprovalButtonsRow: NSView {
    private let onChoose: (String) -> Void

    /// Fully custom strip: (title, behavior, tooltip) per button. `leading` lines
    /// the strip up with the text of the row above it — 21 under a menu item's icon
    /// column, wider on the island where rows start past the mascot.
    init(buttons: [(title: String, behavior: String, toolTip: String?)],
         leading: CGFloat = 21,
         onChoose: @escaping (String) -> Void) {
        self.onChoose = onChoose
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 30))
        autoresizingMask = [.width]

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        for spec in buttons {
            let b = makeButton(spec.title, behavior: spec.behavior)
            b.toolTip = spec.toolTip
            stack.addArrangedSubview(b)
        }
    }

    /// The native-request strip (Claude): Allow / Always / Deny / defer.
    convenience init(hasRule: Bool, ruleToolTip: String?, deferTitle: String,
                     leading: CGFloat = 21,
                     onChoose: @escaping (String) -> Void) {
        var specs: [(title: String, behavior: String, toolTip: String?)] = [
            ("✓ Allow", "allow", nil)
        ]
        if hasRule { specs.append(("✓ Always", "always", ruleToolTip)) }
        specs.append(("✕ Deny", "deny", nil))
        // "⌨ Terminal" for CLI sessions, "⧉ Claude app" for desktop ones.
        specs.append((deferTitle, "defer", "Answer in \(deferTitle.dropFirst(2)) instead"))
        self.init(buttons: specs, leading: leading, onChoose: onChoose)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeButton(_ title: String, behavior: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(clicked(_:)))
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .menuFont(ofSize: 11)
        b.identifier = NSUserInterfaceItemIdentifier(behavior)
        return b
    }

    @objc private func clicked(_ sender: NSButton) {
        let behavior = sender.identifier?.rawValue ?? "allow"
        // Custom views don't auto-dismiss the menu the way item actions do.
        enclosingMenuItem?.menu?.cancelTracking()
        onChoose(behavior)
    }
}
