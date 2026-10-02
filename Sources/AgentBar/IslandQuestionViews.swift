import Cocoa

/// Fallback question card: the writer didn't carry the options (an older hook, or
/// an agent whose questions only live in its own UI), so the card names the
/// question and hands over in one click. Answerable questions render
/// `IslandQuestionCardView` instead.
final class IslandQuestionView: NSView {
    private let onDefer: () -> Void

    init(question: String, deferTitle: String, width: CGFloat, onDefer: @escaping () -> Void) {
        self.onDefer = onDefer
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let head = NSMutableAttributedString(string: "💬 ", attributes: [
            .font: NSFont.systemFont(ofSize: 10),
        ])
        head.append(NSAttributedString(string: "Claude asks", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: IconRenderer.questionDot,
        ]))
        let header = NSTextField(labelWithAttributedString: head)

        let q = NSTextField(wrappingLabelWithString: question)
        q.font = .systemFont(ofSize: 13, weight: .medium)
        q.textColor = .white
        q.preferredMaxLayoutWidth = width

        let go = IslandButton(title: "", target: self, action: #selector(deferClicked))
        go.isBordered = false
        go.attributedTitle = NSAttributedString(string: deferTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ])

        let stack = NSStackView(views: [header, q, go])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: width),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func deferClicked() { onDefer() }
}

/// A question with its options, answerable in place. One tap answers the common
/// case (one question, one choice). A multi-question call becomes a wizard: one
/// question on the card at a time with a "2/4" mark, a single-select tap records
/// the choice and slides to the next question, and the last answer submits the
/// whole set — four questions are four taps, and the card never outgrows the
/// screen. multiSelect steps toggle and move on with a Next button. The terminal
/// wizard renders in parallel while the hook waits, so whoever answers first
/// wins — this card is the "without leaving the screen you're on" way.
///
/// Selections and the wizard step live OUTSIDE the view (the island rebuilds its
/// rows on every store tick, so anything stateful in a row is torn down within
/// seconds): the card is handed the current state and reports every change back
/// to its owner.
final class IslandQuestionCardView: NSView {
    private let questions: [ApprovalRequest.Context.Question]
    private let step: Int
    private let onAnswer: ([[String]]) -> Void
    private let onSelect: ([Set<Int>]) -> Void
    private let onStep: (Int) -> Void
    private var selections: [Set<Int>]
    private var optionButtons: [IslandOptionButton] = []
    private var actionButton: IslandButton?
    /// One advance per card build: a double-tap during the beat between choosing
    /// and sliding must not skip a question.
    private var advancePending = false

    private var isWizard: Bool { questions.count > 1 }
    private var isLastStep: Bool { step >= questions.count - 1 }
    private var current: ApprovalRequest.Context.Question { questions[step] }

    init(questions: [ApprovalRequest.Context.Question], selections: [Set<Int>],
         step: Int, deferTitle: String, width: CGFloat,
         onAnswer: @escaping ([[String]]) -> Void,
         onSelect: @escaping ([Set<Int>]) -> Void,
         onStep: @escaping (Int) -> Void,
         onDefer: @escaping () -> Void) {
        self.questions = questions
        self.step = max(0, min(step, questions.count - 1))
        // Stored selections belong to the request they were made on; if a new
        // request reuses the file name with a different shape, an out-of-range
        // option index must drop rather than crash the submit.
        self.selections = selections.count == questions.count
            ? zip(selections, questions).map { sel, q in sel.filter { $0 < q.options.count } }
            : Array(repeating: [], count: questions.count)
        self.onAnswer = onAnswer
        self.onSelect = onSelect
        self.onStep = onStep
        self.deferAction = onDefer
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        var rows: [NSView] = []
        let q = current
        rows.append(headerRow(q, width: width))
        let text = NSTextField(wrappingLabelWithString: q.question)
        text.font = .systemFont(ofSize: 13, weight: .medium)
        text.textColor = .white
        text.preferredMaxLayoutWidth = width
        rows.append(text)

        // The ✓ column stays through a wizard even on single-select steps, so
        // stepping Back shows the recorded choice and labels never shift.
        let showsCheck = isWizard || q.multiSelect
        for (oi, opt) in q.options.enumerated() {
            let b = IslandOptionButton(
                label: opt.label, description: opt.description,
                showsCheck: showsCheck, width: width
            ) { [weak self] in self?.tapped(option: oi) }
            b.selected = self.selections[self.step].contains(oi)
            optionButtons.append(b)
        }
        let optionStack = NSStackView(views: optionButtons)
        optionStack.orientation = .vertical
        optionStack.alignment = .leading
        optionStack.spacing = 5
        rows.append(optionStack)

        // Single-select steps advance on the tap itself; only multiSelect needs a
        // button to say "these are all I'm picking".
        if q.multiSelect {
            let b = IslandButton(title: "", target: self, action: #selector(actionClicked))
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 7
            b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
            b.attributedTitle = NSAttributedString(
                string: isWizard && !isLastStep ? "Next" : "Answer",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.black,
                ])
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            b.widthAnchor.constraint(equalToConstant: width).isActive = true
            actionButton = b
            rows.append(b)
        }

        rows.append(bottomRow(deferTitle: deferTitle, width: width))

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
        ])
        for b in optionButtons { b.widthAnchor.constraint(equalToConstant: width).isActive = true }
        syncActionButton()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private let deferAction: () -> Void

    private func tapped(option oi: Int) {
        guard !advancePending else { return }
        if current.multiSelect {
            if selections[step].contains(oi) { selections[step].remove(oi) }
            else { selections[step].insert(oi) }
            for (i, b) in optionButtons.enumerated() { b.selected = selections[step].contains(i) }
            syncActionButton()
            onSelect(selections)
            return
        }
        selections[step] = [oi] // radio within its own question
        for (i, b) in optionButtons.enumerated() { b.selected = i == oi }
        onSelect(selections)
        if !isWizard {
            // The common case answers like Allow does: one tap, done.
            submit()
            return
        }
        if isLastStep {
            submit()
            return
        }
        // A beat with the choice highlighted, then the next question slides in —
        // an instant swap read as the tap not registering. The step callback is
        // captured on its own: a store tick can tear this view down during the
        // beat, and the advance must land regardless (the controller owns the
        // step; setting an absolute index is idempotent).
        advancePending = true
        let next = step + 1
        let advance = onStep
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            advance(next)
        }
    }

    private func syncActionButton() {
        guard let b = actionButton else { return }
        // Next needs this step chosen; a final Answer needs the whole set.
        let ready = isWizard && !isLastStep
            ? !selections[step].isEmpty
            : selections.allSatisfy { !$0.isEmpty }
        b.isEnabled = ready
        b.alphaValue = ready ? 1 : 0.35
    }

    @objc private func actionClicked() {
        guard !selections[step].isEmpty else { return }
        if isWizard && !isLastStep { onStep(step + 1); return }
        submit()
    }

    private func submit() {
        // Reaching the end with a hole (possible after stepping Back and forth)
        // returns to the first unanswered question instead of failing silently.
        if let hole = selections.firstIndex(where: { $0.isEmpty }), hole != step {
            onStep(hole)
            return
        }
        guard selections.allSatisfy({ !$0.isEmpty }) else { return }
        let labels = zip(questions, selections).map { q, sel in
            sel.sorted().map { q.options[$0].label }
        }
        onAnswer(labels)
    }

    @objc private func deferClicked() { deferAction() }
    @objc private func backClicked() { onStep(step - 1) }

    /// "● Auth                    2/4" — names the step the way the approval card
    /// names itself, with the wizard's position kept quietly to the right.
    private func headerRow(_ q: ApprovalRequest.Context.Question, width: CGFloat) -> NSView {
        let title = q.header.isEmpty
            ? (isWizard ? "Question \(step + 1)" : "Question") : q.header
        let out = NSMutableAttributedString(string: "● ", attributes: [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: IconRenderer.questionDot,
        ])
        out.append(NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ]))
        let label = NSTextField(labelWithAttributedString: out)
        guard isWizard else { return label }
        let progress = NSTextField(labelWithString: "\(step + 1)/\(questions.count)")
        progress.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        progress.textColor = NSColor.white.withAlphaComponent(0.4)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, spacer, progress])
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    /// "‹ Back" on the left (past the first step), the defer escape on the right.
    private func bottomRow(deferTitle: String, width: CGFloat) -> NSView {
        var views: [NSView] = []
        if isWizard && step > 0 {
            let back = IslandButton(title: "", target: self, action: #selector(backClicked))
            back.isBordered = false
            back.attributedTitle = NSAttributedString(string: "‹ Back", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.white.withAlphaComponent(0.5),
            ])
            views.append(back)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(spacer)
        let escape = IslandButton(title: "", target: self, action: #selector(deferClicked))
        escape.isBordered = false
        escape.attributedTitle = NSAttributedString(string: deferTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ])
        views.append(escape)
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    // MARK: Free text (extension point: IslandOptionButton.freeTextRow)
    // The wizard's "type something" answer stays terminal-only for now — the
    // non-activating panel cannot take keyboard focus safely.
}

/// One tappable option: label, quiet description, and — in toggle mode — a ✓
/// column that keeps its width whether or not it is shown, so labels never shift.
final class IslandOptionButton: NSView {
    private let onTap: () -> Void
    private let check = NSTextField(labelWithString: "✓")
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    var selected = false {
        didSet {
            check.alphaValue = selected ? 1 : 0
            needsDisplay = true
        }
    }

    init(label: String, description: String, showsCheck: Bool, width: CGFloat,
         onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        check.font = .systemFont(ofSize: 11, weight: .semibold)
        check.textColor = IconRenderer.questionDot
        check.alphaValue = 0
        check.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = NSColor.white.withAlphaComponent(0.92)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.translatesAutoresizingMaskIntoConstraints = false

        addSubview(title)
        let textLeading: CGFloat = showsCheck ? 10 + 14 + 4 : 10
        if showsCheck {
            addSubview(check)
            NSLayoutConstraint.activate([
                check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                check.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                check.widthAnchor.constraint(equalToConstant: 14),
            ])
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: textLeading),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        ])

        if description.isEmpty {
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6).isActive = true
        } else {
            let sub = NSTextField(wrappingLabelWithString: description)
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = NSColor.white.withAlphaComponent(0.55)
            sub.maximumNumberOfLines = 2
            sub.lineBreakMode = .byTruncatingTail // a hard cut mid-sentence needs its …
            sub.preferredMaxLayoutWidth = width - textLeading - 10
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
            NSLayoutConstraint.activate([
                sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                sub.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
                sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
                sub.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            ])
        }
        heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) { onTap() }
    /// Same reason as IslandButton: the panel never becomes key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // One notch quieter than the approval buttons at rest, so a prominent
        // Answer button (when present) still leads the card.
        let alpha: CGFloat = selected ? 0.16 : (hovered ? 0.12 : 0.07)
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
}
