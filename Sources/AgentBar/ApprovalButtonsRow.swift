import Cocoa

/// One-line Allow / Always / Deny button strip rendered inside a menu item
/// (NSMenuItem.view), so a pending approval is answerable without a submenu.
final class ApprovalButtonsRow: NSView {
    private let onChoose: (String) -> Void

    init(hasRule: Bool, ruleToolTip: String?, deferTitle: String,
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
            // 21pt leading lines the strip up with menu item text (icon column).
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 21),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        stack.addArrangedSubview(makeButton("✓ Allow", behavior: "allow"))
        if hasRule {
            let always = makeButton("✓ Always", behavior: "always")
            always.toolTip = ruleToolTip
            stack.addArrangedSubview(always)
        }
        stack.addArrangedSubview(makeButton("✕ Deny", behavior: "deny"))
        // "⌨ Terminal" for CLI sessions, "⧉ Claude app" for desktop ones.
        let deferButton = makeButton(deferTitle, behavior: "defer")
        deferButton.toolTip = "Answer in \(deferTitle.dropFirst(2)) instead"
        stack.addArrangedSubview(deferButton)
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
