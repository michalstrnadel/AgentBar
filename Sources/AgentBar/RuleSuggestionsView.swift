import Cocoa

/// Settings ▸ Rules, under the list: up to two rules your own answers suggest
/// (`RuleSuggestions`). Each line says what you did and how often; "Write it…"
/// opens the sheet filled in and set to Watching; × puts that one away for good.
/// Hidden when there is nothing to suggest, so the page is no longer for it.
final class RuleSuggestionsView: NSView {
    var onWrite: ((RuleSheet.Prefill) -> Void)?
    /// The view showed or hid, or changed height: the window re-fits.
    var onResize: (() -> Void)?

    private static let shown = 2
    private let stack = NSStackView()
    private var suggestions: [RuleSuggestions.Suggestion] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }

    var isEmpty: Bool { suggestions.isEmpty }

    func reload() {
        let rules: [RulesStore.Rule]
        if case .rules(let r) = RulesStore.load() { rules = r } else { rules = [] }
        suggestions = RuleSuggestions.make(ledger: DecisionLedger.cached(), rules: rules,
                                           dismissed: RuleSuggestions.dismissed)
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        guard !suggestions.isEmpty else { onResize?(); return }
        let title = NSTextField(labelWithString: "Suggested from your answers")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)
        for (i, s) in suggestions.prefix(Self.shown).enumerated() { stack.addArrangedSubview(row(s, i)) }
        if suggestions.count > Self.shown {
            let more = NSTextField(labelWithString: "\(suggestions.count - Self.shown) more after these")
            more.font = .systemFont(ofSize: 11)
            more.textColor = .tertiaryLabelColor
            stack.addArrangedSubview(more)
        }
        onResize?()
    }

    private func row(_ s: RuleSuggestions.Suggestion, _ index: Int) -> NSView {
        let verb = s.decision == "allow" ? "Allowed" : "Denied"
        let place = (s.cwd as NSString).lastPathComponent
        let what = NSTextField(labelWithString: "\(verb) \(readable(s.shape)) \(s.count)× in \(place), every time")
        what.font = .systemFont(ofSize: 12)
        what.lineBreakMode = .byTruncatingMiddle
        what.toolTip = "\(s.display)\n\(s.cwd)"
        what.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let write = NSButton(title: "Write it…", target: self, action: #selector(writeClicked(_:)))
        write.bezelStyle = .rounded
        write.controlSize = .small
        write.font = .systemFont(ofSize: 11)
        write.tag = index
        write.toolTip = "Opens a rule set to Watching: it answers nothing until you let it."

        let dismiss = NSButton(title: "", target: self, action: #selector(dismissClicked(_:)))
        dismiss.bezelStyle = .inline
        dismiss.isBordered = false
        dismiss.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Don't suggest this again")
        dismiss.tag = index
        dismiss.toolTip = "Don't suggest this again"

        let line = NSStackView(views: [what, NSView(), write, dismiss])
        line.orientation = .horizontal
        line.spacing = 6
        line.alignment = .centerY
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: SettingsWindow.minWidth - 58).isActive = true
        return line
    }

    /// `bash:npm test` reads as `npm test`; any other kind keeps its word.
    private func readable(_ shape: String) -> String {
        shape.hasPrefix("bash:") ? String(shape.dropFirst(5))
            : shape.replacingOccurrences(of: ":", with: " ")
    }

    @objc private func writeClicked(_ sender: NSButton) {
        guard suggestions.indices.contains(sender.tag) else { return }
        onWrite?(RuleSuggestions.prefill(suggestions[sender.tag]))
    }

    @objc private func dismissClicked(_ sender: NSButton) {
        guard suggestions.indices.contains(sender.tag) else { return }
        RuleSuggestions.dismiss(suggestions[sender.tag])
        reload()
    }
}
