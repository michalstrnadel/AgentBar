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
            // Read without the glyph: "check mark Allow" is the symbol's name, not
            // the button's.
            b.setAccessibilityLabel(Self.spoken(spec.title))
            stack.addArrangedSubview(b)
        }
    }

    /// A title without its leading glyph: `✓ Allow` → `Allow`.
    static func spoken(_ title: String) -> String {
        guard let first = title.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first),
              let space = title.firstIndex(of: " ")
        else { return title }
        return String(title[title.index(after: space)...])
    }

    /// The native-request strip (Claude): Allow / Always / Deny / defer.
    convenience init(hasRule: Bool, ruleToolTip: String?, deferTitle: String,
                     leading: CGFloat = 21, promoteAlways: Bool = false,
                     onChoose: @escaping (String) -> Void) {
        var specs: [(title: String, behavior: String, toolTip: String?)] = [
            ("✓ Allow", "allow", nil)
        ]
        if hasRule { specs.append(("✓ Always", "always", ruleToolTip)) }
        specs.append(("✕ Deny", "deny", nil))
        // "⌨ Terminal" for CLI sessions, "⧉ Claude app" for desktop ones.
        specs.append((deferTitle, "defer", "Answer in \(deferTitle.dropFirst(2)) instead"))
        self.init(buttons: specs, leading: leading, onChoose: onChoose)
        // The nudge, when the same prompt has been allowed over and over and never
        // refused: weight only. A coloured button in a menu reads as the safe
        // default, and "make the agent stop asking" is not a default anyone else
        // gets to pick.
        if promoteAlways, let always = button(for: "always") {
            always.font = .boldSystemFont(ofSize: NSFont.menuFont(ofSize: 11).pointSize)
        }
    }

    private func button(for behavior: String) -> NSButton? {
        (subviews.first as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == behavior }
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
