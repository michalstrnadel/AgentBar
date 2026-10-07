import Cocoa

/// Draws `DecisionWeek` in Settings ▸ Approvals: the prompts that held your agents
/// up most this week, and what the rules you wrote did about them.
///
/// Its own file for the reason `RulesView` is: a list that builds a variable number
/// of rows and re-lays itself out is not a checkbox. It decides nothing and writes
/// nothing — "Write a rule…" hands a prefilled sheet to the window (`onWriteRule`),
/// and the person saves it or does not.
final class DecisionWeekView: NSView {
    /// The row count changed, so the window can re-fit.
    var onResize: (() -> Void)?
    /// The person asked to write a rule from one of the rows.
    var onWriteRule: ((RuleSheet.Prefill) -> Void)?

    private static let width = SettingsChrome.cardWidth - SettingsChrome.rowInset * 2
    private let column = NSStackView()
    private var items: [DecisionWeek.Item] = []
    private var drawn: DecisionWeek.Week?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        reload()
    }

    required init?(coder: NSCoder) { nil }

    /// Shown again, or brought back to the front: a week moves on its own.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey),
                                               name: NSWindow.didBecomeKeyNotification,
                                               object: window)
        reload()
    }

    @objc private func windowBecameKey() { reload() }

    func reload(now: Date = Date()) {
        let week = DecisionWeek.make(ledger: DecisionLedger.cached(),
                                     rules: RulesStore.cached().rules, now: now)
        guard week != drawn else { return }
        drawn = week
        items = week.items
        for v in column.arrangedSubviews { v.removeFromSuperview() }

        let title = NSTextField(labelWithString: "Your week of decisions")
        title.font = .systemFont(ofSize: 13.5)
        column.addArrangedSubview(title)

        guard !week.isEmpty else {
            column.addArrangedSubview(label(DecisionWeek.emptyText(ledgerOn: DecisionLedger.enabled),
                                            size: 11.5, colour: .secondaryLabelColor, wraps: true))
            onResize?()
            return
        }
        let summary = label(DecisionWeek.summary(week, now: now), size: 11.5,
                            colour: .secondaryLabelColor, wraps: true)
        column.addArrangedSubview(summary)
        column.setCustomSpacing(SettingsChrome.Space.step, after: summary)

        for (i, item) in week.items.enumerated() {
            let r = row(item, index: i, now: now)
            column.addArrangedSubview(r)
            column.setCustomSpacing(6, after: r)
        }

        // What the numbers cannot see, said once rather than hidden in a tooltip.
        var foot = "Only prompts answered in AgentBar are counted."
        if week.more > 0 {
            foot = "\(week.more) more not shown. " + foot
        }
        if !DecisionLedger.enabled {
            foot = "Remember what I decided is off, so nothing new is counted. " + foot
        }
        column.addArrangedSubview(label(foot, size: 10.5, colour: .tertiaryLabelColor, wraps: true))
        onResize?()
    }

    private func row(_ item: DecisionWeek.Item, index: Int, now: Date) -> NSView {
        let what = label(RulesView.readable(item.shape), size: 11.5, colour: .labelColor)
        what.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        what.lineBreakMode = .byTruncatingTail
        what.toolTip = item.display.isEmpty ? nil : "Latest: " + item.display
        what.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let figure = label(DecisionWeek.figure(item), size: 11, colour: .secondaryLabelColor)
        figure.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        figure.setContentCompressionResistancePriority(.required, for: .horizontal)
        if item.untimed > 0 {
            figure.toolTip = "\(item.untimed) of these carry no wait time — written by an older "
                + "hook — so the total is a floor."
        }

        let top = NSStackView(views: [what, spacer(), figure])
        top.orientation = .horizontal
        top.spacing = 6
        top.alignment = .firstBaseline

        let detail = label(DecisionWeek.detail(item, now: now), size: 10.5,
                           colour: .secondaryLabelColor)
        detail.lineBreakMode = .byTruncatingTail
        detail.toolTip = detail.stringValue
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var bottomViews: [NSView] = [detail, spacer()]
        if item.offer != nil {
            let write = NSButton(title: "Write a rule…", target: self, action: #selector(writeRule(_:)))
            write.bezelStyle = .inline
            write.controlSize = .small
            write.font = .systemFont(ofSize: 10.5)
            write.tag = index
            write.toolTip = "Opens the rule sheet filled in from this prompt. It starts out "
                + "Watching, and nothing is saved until you press Add rule."
            write.setContentCompressionResistancePriority(.required, for: .horizontal)
            bottomViews.append(write)
        }
        let bottom = NSStackView(views: bottomViews)
        bottom.orientation = .horizontal
        bottom.spacing = 8
        bottom.alignment = .centerY

        let stack = NSStackView(views: [top, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        bottom.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    private func label(_ text: String, size: CGFloat, colour: NSColor,
                       wraps: Bool = false) -> NSTextField {
        let l = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size)
        l.textColor = colour
        l.isSelectable = false
        if wraps { SettingsChrome.fit(l, to: Self.width) }
        return l
    }

    @objc private func writeRule(_ sender: NSButton) {
        guard items.indices.contains(sender.tag),
              let prefill = DecisionWeek.prefill(items[sender.tag]) else { return }
        onWriteRule?(prefill)
    }
}
