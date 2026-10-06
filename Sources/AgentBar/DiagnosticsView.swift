import Cocoa

/// The Diagnostics section of the Settings window: what `Diagnostics` found, and
/// the button that copies all of it for a bug report.
///
/// It shows **only what needs attention**. Twenty-five green rows is a wall to
/// read through for the one line that matters, and a status app that fills a
/// window with reassurance is doing the opposite of staying out of the way. When
/// everything passes it says so in one line; the copied report always carries
/// every check, because that is the thing someone else has to read.
///
/// Its own file rather than another method on `SettingsWindow` for the same reason
/// `DisplayPicker` is: a section that builds a variable number of subviews and
/// re-lays itself out is not a checkbox.
final class DiagnosticsView: NSView {
    /// Fired when the row count changed, so the window can re-fit. Both ways —
    /// growing *and* shrinking; a section that only re-fits when it gets bigger
    /// leaves a hole under it when it gets smaller.
    var onResize: (() -> Void)?

    /// More than this and the window runs off the bottom of the screen. The rest are
    /// in the report, which is where a long list belongs anyway.
    private static let maxRows = 4
    /// Matches the Settings window's content width less its insets and the row's own
    /// bullet gutter, so a fix wraps once rather than becoming a paragraph.
    private static let textWidth = SettingsWindow.minWidth - 58

    private(set) var rows = NSStackView()
    private let summary = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy report", target: nil, action: nil)
    private var checks: [Diagnostics.Check] = []
    private var running = false
    /// The repair behind each **Fix it** button, by the button's tag. A row is
    /// rebuilt on every refresh, so this is rebuilt with it.
    private var repairs: [Diagnostics.Repair] = []
    private let testButton = NSButton()
    private let testResult = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        summary.font = .systemFont(ofSize: 11)
        summary.lineBreakMode = .byTruncatingTail

        copyButton.target = self
        copyButton.action = #selector(copyReport)
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.font = .systemFont(ofSize: 11)
        copyButton.toolTip = "Copy every check, passing ones included — this is what to paste into an issue."

        let recheck = NSButton(title: "Re-check", target: self, action: #selector(refresh))
        recheck.bezelStyle = .rounded
        recheck.controlSize = .small
        recheck.font = .systemFont(ofSize: 11)

        testButton.title = "Test an approval"
        testButton.target = self
        testButton.action = #selector(selfTest)
        testButton.bezelStyle = .rounded
        testButton.controlSize = .small
        testButton.font = .systemFont(ofSize: 11)
        testButton.toolTip = "Raises a real approval through the real hook. Answer it like any other."

        testResult.font = .systemFont(ofSize: 10)
        testResult.textColor = .secondaryLabelColor
        testResult.preferredMaxLayoutWidth = Self.textWidth
        testResult.isHidden = true

        let header = NSStackView(views: [summary, NSView(), testButton, recheck, copyButton])
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8

        let stack = NSStackView(views: [header, testResult, rows])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Re-runs the checks. Off the main thread: the node probe shells out to the
    /// login shell on a version-manager setup, which is hundreds of milliseconds,
    /// and a Settings window that hangs while opening is its own bug report.
    @objc func refresh() {
        guard !running else { return }
        running = true
        summary.stringValue = "Checking…"
        summary.textColor = .secondaryLabelColor
        copyButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Diagnostics.run()
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                self.copyButton.isEnabled = true
                self.apply(found)
            }
        }
    }

    /// Internal rather than private so a test can draw a report without running the checks.
    func apply(_ found: [Diagnostics.Check]) {
        checks = found
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let failed = found.filter { $0.status == .fail }
        let warned = found.filter { $0.status == .warn }
        let attention = failed + warned

        if attention.isEmpty {
            summary.stringValue = "\(found.count) checks, nothing wrong."
            summary.textColor = .secondaryLabelColor
        } else {
            var parts: [String] = []
            if !failed.isEmpty { parts.append("\(failed.count) broken") }
            if !warned.isEmpty { parts.append("\(warned.count) worth a look") }
            summary.stringValue = parts.joined(separator: " · ")
            summary.textColor = failed.isEmpty ? .secondaryLabelColor : .systemRed
        }

        repairs.removeAll()
        for check in attention.prefix(Self.maxRows) {
            let view = row(check)
            rows.addArrangedSubview(view)
            // Only once it is in `rows`: a constraint between two views with no common
            // ancestor raises, and every row with a repair button used to do exactly
            // that, taking the rest of the report down with it.
            if check.repair != nil { view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true }
        }
        if attention.count > Self.maxRows {
            let more = NSTextField(labelWithString:
                "…and \(attention.count - Self.maxRows) more — they are all in the copied report.")
            more.font = .systemFont(ofSize: 11)
            more.textColor = .tertiaryLabelColor
            rows.addArrangedSubview(more)
        }
        onResize?()
    }

    private func row(_ check: Diagnostics.Check) -> NSView {
        let dot = NSTextField(labelWithString: check.status == .fail ? "✕" : "!")
        dot.font = .systemFont(ofSize: 11, weight: .bold)
        dot.textColor = check.status == .fail ? .systemRed : .systemOrange
        dot.widthAnchor.constraint(equalToConstant: 12).isActive = true

        let title = NSTextField(labelWithString: check.title)
        title.font = .systemFont(ofSize: 11, weight: .medium)

        var lines = [title]
        // The detail says what is wrong; the fix says what to do. Both, or the row
        // is just a nicer way of saying "something is broken".
        for (text, color) in [(check.detail, NSColor.secondaryLabelColor),
                              (check.fix.map { "→ \($0)" }, NSColor.tertiaryLabelColor)] {
            guard let text else { continue }
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 10)
            label.textColor = color
            label.preferredMaxLayoutWidth = Self.textWidth
            lines.append(label)
        }

        let text = NSStackView(views: lines)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        var parts: [NSView] = [dot, text]
        // A fix AgentBar can carry out itself gets a button, and only then. Every
        // check has carried its fix in words since 1.21.0; the ones worth a button
        // are the three the app already does at launch, so the sentence "relaunch
        // AgentBar" stops being an instruction and starts being a click.
        if let repair = check.repair {
            let button = NSButton(title: repair.title, target: self, action: #selector(fix(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.tag = repairs.count
            repairs.append(repair)
            parts += [NSView(), button]
        }

        let row = NSStackView(views: parts)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        return row
    }

    /// Does the thing the row's sentence describes, then re-checks — because the
    /// answer to "did that work" is the same report, and saying so is the whole
    /// point of a button here.
    @objc private func fix(_ sender: NSButton) {
        guard repairs.indices.contains(sender.tag), !running else { return }
        let repair = repairs[sender.tag]
        let was = sender.title
        sender.isEnabled = false
        sender.title = "Fixing…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let problems = Diagnostics.apply(repair)
            DispatchQueue.main.async {
                sender.title = problems.isEmpty ? was : "Could not"
                sender.toolTip = problems.isEmpty ? nil : problems.joined(separator: "\n")
                sender.isEnabled = true
                if !problems.isEmpty, let window = self?.window {
                    // What did not happen, in the words the pass logged it with:
                    // "Could not" alone sends somebody to Console.app to find out.
                    let alert = NSAlert()
                    alert.messageText = "\(repair.title) did not finish"
                    alert.informativeText = problems.joined(separator: "\n")
                    alert.beginSheetModal(for: window)
                }
                self?.refresh()
            }
        }
    }

    /// The one check that does not read a file and reason about it: it raises a real
    /// approval through the real hook and waits for the human to answer it. Every
    /// other row can pass while the thing they describe has never actually run —
    /// which is exactly what happened here for six releases.
    @objc private func selfTest() {
        guard !running else { return }
        testButton.isEnabled = false
        testButton.title = "Answer it…"
        testResult.stringValue = "A card should be waiting for you in the menu bar. Answer it."
        testResult.textColor = .secondaryLabelColor
        testResult.isHidden = false
        onResize?()
        ApprovalSelfTest.run { [weak self] outcome in
            guard let self else { return }
            self.testButton.isEnabled = true
            self.testButton.title = "Test an approval"
            self.testResult.stringValue = outcome.line
            if case .answered = outcome {
                self.testResult.textColor = .secondaryLabelColor
            } else {
                self.testResult.textColor = .systemOrange
            }
            self.onResize?()
        }
    }

    @objc private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diagnostics.report(checks), forType: .string)
        let was = copyButton.title
        copyButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak copyButton] in
            copyButton?.title = was
        }
    }
}
