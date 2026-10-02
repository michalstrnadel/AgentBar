import Cocoa

/// The pending approval, shown under the session that raised it: what will run,
/// and the buttons to answer it without leaving the panel. Deny and Allow lead;
/// "Always allow" and handing the prompt back to the terminal stay available but
/// quiet. Shortcut hints appear only when the global shortcut is actually on, so
/// the panel never advertises a key that does nothing.
final class IslandApprovalView: NSView, NSTextFieldDelegate {
    private let onChoose: (String) -> Void
    /// Deny, with what to do instead. Separate from `onChoose` because it carries
    /// text, and because every other verb must stay unable to.
    private let onDenyNote: (String) -> Void
    /// Told when the note field opens (true) and closes (false). The controller
    /// needs both: while a note is being typed the panel has to take keys, stay
    /// open when the pointer wanders, and stop rebuilding rows under the caret.
    private let onCompose: (Bool) -> Void

    private var answerRows: [NSView] = []
    private var composeRows: [NSView] = []
    /// Internal rather than private so the render harness can draw it filled in.
    let noteField = IslandNoteField()
    private(set) var composing = false

    init(request: ApprovalRequest, deferTitle: String, cwd: String = "", width: CGFloat,
         onChoose: @escaping (String) -> Void,
         onDenyNote: @escaping (String) -> Void = { _ in },
         onCompose: @escaping (Bool) -> Void = { _ in }) {
        self.onChoose = onChoose
        self.onDenyNote = onDenyNote
        self.onCompose = onCompose
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let plan = request.isPlanRequest ? (request.planText ?? "(plan text missing)") : nil
        var rows: [NSView] = [Self.header(plan: plan != nil)]
        if plan == nil, let tool = Self.toolLine(request) { rows.append(tool) }
        if let plan {
            // The whole plan, readable in place — this card is a review, not a
            // prompt. Long plans scroll inside the box rather than growing it.
            rows.append(Self.planBox(plan, width: width))
        } else if let context = request.context {
            let box = NSView()
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            box.layer?.cornerRadius = 6
            let ctx = ApprovalContextView(context: context, leading: 10)
            ctx.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(ctx)
            NSLayoutConstraint.activate([
                ctx.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                ctx.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                ctx.topAnchor.constraint(equalTo: box.topAnchor, constant: 3),
                ctx.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -3),
                ctx.heightAnchor.constraint(equalToConstant: ctx.frame.height),
            ])
            rows.append(box)
            if let summary = Self.diffSummary(context) { rows.append(summary) }
        }

        // What you did about this exact prompt before, where you are deciding it
        // again. Absent below two, because "allowed 1× here" is the thing you just
        // did. See `DecisionLedger`.
        let past = DecisionLedger.summary(shape: DecisionLedger.shape(of: request), cwd: cwd,
                                          in: DecisionLedger.cached())
        let promote = plan == nil
            && DecisionLedger.shouldPromoteAlways(past, hasRule: request.ruleSuggestion != nil)
        if let hint = DecisionLedger.hint(past), plan == nil {
            rows.append(Self.pastLine(hint))
        }
        // The same answer every time, often enough to be a habit. The offer is a
        // link, not a default: it opens a sheet that says what the rule would and
        // would not answer, and nothing is written until Add is pressed.
        let offer = plan == nil ? DecisionLedger.shouldOfferRule(past) : nil

        let shortcuts = UserDefaults.standard.bool(forKey: "globalApprovalShortcut")
        let deny = Self.button(plan != nil ? "Keep planning" : "Deny",
                               hint: shortcuts ? KeyCombo.deny.display : nil,
                               prominent: false, target: self, action: #selector(denyClicked))
        let allow = Self.button(plan != nil ? "Approve plan" : "Allow",
                                hint: shortcuts ? KeyCombo.allow.display : nil,
                                prominent: true, target: self, action: #selector(allowClicked))
        if plan != nil {
            // Say where the click lands: this one leaves the island and answers
            // the session's own dialog.
            allow.toolTip = "Jumps to the session and answers its plan dialog"
            deny.toolTip = "Tells Claude to refine the plan before making changes"
        }
        let main = NSStackView(views: [deny, allow])
        main.orientation = .horizontal
        main.distribution = .fillEqually
        main.spacing = 8
        rows.append(main)

        var secondary: [NSView] = []
        // A plan approval hides the rule link even when a suggestion rides along:
        // "always allow ExitPlanMode" would auto-approve every future plan sight
        // unseen, which defeats the card.
        if request.ruleSuggestion != nil, plan == nil {
            // Weight only when the same prompt has been allowed over and over and
            // never refused. A coloured link would read as the safe default, and
            // "stop asking about this" is not a default anyone else gets to pick —
            // a count is not consent, and neither is a suggestion Claude made.
            let always = Self.link(promote ? "Always allow — stop asking" : "Always allow",
                                   target: self, action: #selector(alwaysClicked),
                                   emphasised: promote)
            always.toolTip = request.ruleMenuTitle
            secondary.append(always)
        }
        if let offer {
            let rule = Self.link("Always \(offer) this here…", target: self,
                                 action: #selector(ruleClicked), emphasised: false)
            rule.toolTip = "Writes a rule of your own — narrower than it looks, and every "
                + "time it fires the approval history names it."
            secondary.append(rule)
        }
        // Refusing with a reason is the one way to steer rather than stop: the note
        // reaches the agent as the denial's message. For a plan it is the feedback
        // the plan goes back with.
        let noteLink = Self.link(plan != nil ? "Say what to change…" : "Deny with a note…",
                                 target: self, action: #selector(composeClicked))
        noteLink.toolTip = plan != nil
            ? "Sends the plan back with your feedback, and Claude keeps planning"
            : "Refuses, and tells the agent what to do instead"
        secondary.insert(noteLink, at: 0)
        secondary.append(Self.link(deferTitle, target: self, action: #selector(deferClicked)))
        let secondaryRow = NSStackView(views: secondary)
        secondaryRow.orientation = .horizontal
        secondaryRow.spacing = 14
        rows.append(secondaryRow)
        answerRows = [main, secondaryRow]

        // The note row replaces both answer rows while it is open, so the card
        // never shows two ways to deny at once.
        noteField.placeholder = plan != nil ? "What should change in the plan?"
                                            : "What should it do instead?"
        noteField.field.delegate = self
        let send = Self.button(plan != nil ? "Send back" : "Deny & tell it", hint: "↩",
                               prominent: true, target: self, action: #selector(sendNote))
        send.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let cancel = Self.link("Cancel", target: self, action: #selector(cancelNote))
        let composeButtons = NSStackView(views: [cancel, NSView(), send])
        composeButtons.orientation = .horizontal
        composeButtons.spacing = 8
        composeRows = [noteField, composeButtons]
        for v in composeRows { v.isHidden = true; rows.append(v) }

        let stack = NSStackView(views: rows)
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
            widthAnchor.constraint(equalToConstant: width),
            main.widthAnchor.constraint(equalToConstant: width),
            noteField.widthAnchor.constraint(equalToConstant: width),
            composeButtons.widthAnchor.constraint(equalToConstant: width),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - The note

    @objc private func composeClicked() { setComposing(true) }

    @objc private func cancelNote() { setComposing(false) }

    @objc private func sendNote() {
        let text = noteField.stringValue
        setComposing(false, notify: false)
        onDenyNote(text)
    }

    /// `notify: false` when the note was sent: the answer path collapses the island
    /// itself, and telling the controller "composing ended" first would rebuild the
    /// card once for nothing in between.
    func setComposing(_ on: Bool, notify: Bool = true) {
        guard on != composing else { return }
        composing = on
        for v in answerRows { v.isHidden = on }
        for v in composeRows { v.isHidden = !on }
        if !on { noteField.stringValue = "" }
        if notify || on { onCompose(on) }
        if on {
            // After the controller has re-laid the panel and made it key; focusing
            // before that lands the caret in a window that cannot take it yet.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self.noteField.field)
            }
        }
    }

    /// Return sends and Escape backs out — the two keys anybody reaches for in a
    /// one-line field, and the only two this one answers to.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            sendNote(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelNote(); return true
        default:
            return false
        }
    }

    func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
        // A note is prose, but it is prose about commands: `--force` must not
        // arrive as an em dash.
        if let editor = fieldEditor as? NSTextView {
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
        }
        return true
    }

    @objc private func allowClicked() { onChoose("allow") }
    @objc private func denyClicked() { onChoose("deny") }
    @objc private func alwaysClicked() { onChoose("always") }
    @objc private func deferClicked() { onChoose("defer") }
    /// Not a decision about this request: it opens the rule sheet and leaves the
    /// card exactly where it was, still pending, still yours to answer.
    @objc private func ruleClicked() { onChoose("rule") }

    /// "● Permission Request" / "● Plan Review" — names what this card is, the way
    /// the reference does.
    private static func header(plan: Bool) -> NSView {
        let out = NSMutableAttributedString(string: "● ", attributes: [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: IconRenderer.amberDot,
        ])
        out.append(NSAttributedString(string: plan ? "Plan Review" : "Permission Request",
                                      attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ]))
        return NSTextField(labelWithAttributedString: out)
    }

    /// The plan markdown in its own quiet box. Sized to the text up to a cap;
    /// past the cap the box holds still and the text scrolls inside it.
    private static let planMaxHeight: CGFloat = 300
    private static func planBox(_ plan: String, width: CGFloat) -> NSView {
        let inset: CGFloat = 10
        let rendered = MarkdownLite.render(plan)
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = rendered
        label.preferredMaxLayoutWidth = width - inset * 2
        label.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(label)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        scroll.layer?.cornerRadius = 6
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc

        let textHeight = ceil(rendered.boundingRect(
            with: NSSize(width: width - inset * 2, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 6
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: inset),
            label.topAnchor.constraint(equalTo: doc.topAnchor, constant: 8),
            label.widthAnchor.constraint(equalToConstant: width - inset * 2),
            doc.widthAnchor.constraint(equalToConstant: width),
            doc.bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            scroll.widthAnchor.constraint(equalToConstant: width),
            scroll.heightAnchor.constraint(equalToConstant: min(textHeight + 16, planMaxHeight)),
        ])
        return scroll
    }

    /// "⚠︎ Edit  src/auth/middleware.ts" — the tool in warning orange, its target
    /// quiet beside it. Bash skips the target: the command box below carries it
    /// whole, and saying it twice helps nobody.
    private static func toolLine(_ r: ApprovalRequest) -> NSView? {
        guard !r.toolName.isEmpty else { return nil }
        var rest = r.display
        if rest.hasPrefix(r.toolName) { rest.removeFirst(r.toolName.count) }
        while rest.first == ":" || rest.first == " " { rest.removeFirst() }
        if case .bash = r.context { rest = "" }
        let out = NSMutableAttributedString(string: "⚠︎ \(r.toolName)", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.systemOrange,
        ])
        if !rest.isEmpty {
            out.append(NSAttributedString(string: "  \(rest)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            ]))
        }
        let l = NSTextField(labelWithAttributedString: out)
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    /// "+3 −1" under a diff — the size of the change at one glance. The mini-diff
    /// itself already ends with "+N more edits" when truncated, so only the line
    /// counts live here.
    private static func diffSummary(_ context: ApprovalRequest.Context) -> NSView? {
        guard case .diff(let old, let new, _) = context else { return nil }
        // What actually moved. Counting the whole old and new blocks reported a
        // one-character edit inside an eight-line window as "+8 −8", which is a
        // number somebody would repeat.
        func lines(_ s: String) -> [String] {
            s.isEmpty ? [] : s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
        let count = LineDiff.counts(old: lines(old), new: lines(new))
        let out = NSMutableAttributedString(string: "+\(count.added)", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.systemGreen,
        ])
        out.append(NSAttributedString(string: "  −\(count.removed)", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.systemRed,
        ]))
        return NSTextField(labelWithAttributedString: out)
    }

    private static func button(_ title: String, hint: String?, prominent: Bool,
                               target: Any, action: Selector) -> NSButton {
        let b = IslandButton(title: "", target: target, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 7
        b.layer?.backgroundColor = (prominent ? NSColor.white.withAlphaComponent(0.92)
                                              : NSColor.white.withAlphaComponent(0.10)).cgColor
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: prominent ? NSColor.black : NSColor.white,
        ])
        if let hint {
            text.append(NSAttributedString(string: " \(hint)", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: (prominent ? NSColor.black : NSColor.white)
                    .withAlphaComponent(0.45),
            ]))
        }
        b.attributedTitle = text
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return b
    }

    private static func link(_ title: String, target: Any, action: Selector,
                             emphasised: Bool = false) -> NSButton {
        let b = IslandButton(title: "", target: target, action: action)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: emphasised ? .semibold : .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(emphasised ? 0.75 : 0.5),
        ])
        return b
    }

    /// The quiet line above the buttons: what this same prompt got last time, and
    /// how many times. Dimmer than the tool line it sits under — it is context for
    /// a decision, not the decision.
    private static func pastLine(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = NSColor.white.withAlphaComponent(0.45)
        l.lineBreakMode = .byTruncatingTail
        return l
    }
}

/// The one text field on the island: the note that goes with a denial. Drawn for
/// the panel's black rather than the system's light field, and hosted in its own
/// rounded box — a bare field's alignment insets make it overhang the rows above.
final class IslandNoteField: NSView {
    let field = NSTextField()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.cornerRadius = 6
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = .white
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    var placeholder: String = "" {
        didSet {
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.white.withAlphaComponent(0.35),
            ])
        }
    }

    /// A click anywhere on the box, not only on the glyphs, starts typing.
    override func mouseDown(with event: NSEvent) {
        // A plain view does not make a panel with `becomesKeyOnlyIfNeeded` key,
        // so after a click elsewhere the caret would show while keys went on to
        // the terminal.
        window?.makeKey()
        window?.makeFirstResponder(field)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
