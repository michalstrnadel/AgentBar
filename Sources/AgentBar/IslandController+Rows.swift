import Cocoa

/// What the open panel lists: a row per session, the approval and question
/// cards under the sessions that raised them, and the pill's echo of an answer.
extension IslandController {
    func rows() -> [NSView] {
        var out: [NSView] = []
        let visible = visibleSessions
        let rowW = Self.expandedWidth - IslandContentView.hPad * 2
        for (i, s) in visible.prefix(Self.maxRows).enumerated() {
            // The list leads with whatever needs the user, so the first row is the
            // hero — boxed, with the mark; the rest stay one quiet line each.
            let style: IslandRowView.Style = i == 0 ? .hero : .compact
            let mark = IconRenderer.shared.sprite(for: s.agent).restingColor
            let row = IslandRowView(session: s, mark: mark, style: style) { [weak self] session in
                self?.click(session)
            }
            personality.attach(row.mascot, session: s.id)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: rowW).isActive = true
            out.append(row)
            out.append(contentsOf: approvalViews(for: s))
            if let q = questionView(for: s) { out.append(q) }
        }
        if visible.count > Self.maxRows {
            out.append(more(visible.count - Self.maxRows))
        }
        if visible.isEmpty { out.append(emptyRow(width: rowW)) }
        return out
    }

    /// Cards sit under their session, indented just enough to read as belonging
    /// to it rather than to the panel.
    private static let cardIndent: CGFloat = 12

    func card(_ view: NSView) -> NSView {
        let wrapper = NSStackView(views: [view])
        wrapper.orientation = .horizontal
        wrapper.edgeInsets = NSEdgeInsets(top: 0, left: Self.cardIndent, bottom: 0, right: 0)
        return wrapper
    }

    private func deferTitle(for s: Session, plan: Bool = false) -> String {
        let verb = plan ? "Review" : "Answer"
        return s.entrypoint == "claude-desktop" ? "\(verb) in Claude" : "\(verb) in terminal"
    }

    /// The pending request's own detail and buttons — same mini-diff the menu
    /// shows, Deny and Allow in front, the answer echoed in the pill on the way out.
    private func approvalViews(for s: Session) -> [NSView] {
        guard s.state == .permission else { return [] }
        let mine = requests.filter { $0.sessionId == s.id }
        var out: [NSView] = []
        for r in mine {
            if let cached = approvalCards[r.fileName] {
                out.append(cached)
                continue
            }
            let view = card(IslandApprovalView(
                request: r,
                deferTitle: deferTitle(for: s, plan: r.isPlanRequest),
                // The repo the count is scoped to: the same command is routine in
                // one checkout and the opposite in another.
                cwd: s.cwd,
                width: Self.expandedWidth - IslandContentView.hPad * 2 - Self.cardIndent,
                onChoose: { [weak self] behavior in
                // "rule" is not an answer to this request — it opens the sheet and
                // leaves the card pending. Handled before the answer path so a
                // dropped-answer beep can never fire for a click that answered
                // nothing on purpose.
                if behavior == "rule" {
                    SettingsWindow.shared.addRule(from: RuleSheet.Prefill(
                        decision: DecisionLedger.shouldOfferRule(
                            DecisionLedger.summary(shape: DecisionLedger.shape(of: r),
                                                   cwd: s.cwd, in: DecisionLedger.cached())) ?? "allow",
                        shape: DecisionLedger.shape(of: r),
                        cwd: r.cwd.isEmpty ? s.cwd : r.cwd,
                        display: r.display))
                    return
                }
                // Only confirm what actually reached disk: a dropped answer leaves the
                // request pending, and a "✓ Allowed" flash would be a lie.
                guard AgentActions.answer(ApprovalAction(request: r, behavior: behavior, session: s))
                else { return }
                self?.flashAnswer(behavior, plan: r.isPlanRequest)
            }, onDenyNote: { [weak self] text in
                guard let self else { return }
                self.endComposing(relayout: false)
                let noted = DenyNote.clean(text) != nil
                guard AgentActions.answer(ApprovalAction(request: r, behavior: "deny", session: s,
                                                         note: text))
                else { self.rebuild(animated: true); return }
                self.flashAnswer(noted ? "denyNote" : "deny", plan: r.isPlanRequest)
            }, onCompose: { [weak self] on in
                guard let self else { return }
                if on { self.beginComposing(r.fileName) } else { self.endComposing() }
            }))
            approvalCards[r.fileName] = view
            out.append(view)
        }
        return out
    }

    /// The question card under a session that asked one. When the hook carried the
    /// options, the card is answerable in place; otherwise it names the question
    /// and hands over in one click.
    private func questionView(for s: Session) -> NSView? {
        guard s.state == .question else { return nil }
        let width = Self.expandedWidth - IslandContentView.hPad * 2 - Self.cardIndent
        if let r = requests.first(where: { $0.sessionId == s.id }), let qs = r.questions {
            return card(IslandQuestionCardView(
                questions: qs,
                selections: questionSelections[r.fileName] ?? [],
                step: questionSteps[r.fileName] ?? 0,
                deferTitle: deferTitle(for: s),
                width: width,
                onAnswer: { [weak self] labels in
                    guard AgentActions.answerQuestion(labels, request: r) else { return }
                    self?.questionSelections[r.fileName] = nil
                    self?.questionSteps[r.fileName] = nil
                    self?.flashAnswer("answer")
                },
                onSelect: { [weak self] selections in
                    self?.questionSelections[r.fileName] = selections
                },
                onStep: { [weak self] step in
                    guard let self else { return }
                    self.questionSteps[r.fileName] = step
                    // The next question replaces this one in place; the panel
                    // resizes to fit it.
                    self.layout(animated: true)
                },
                onDefer: { [weak self] in
                    guard let self else { return }
                    self.questionSelections[r.fileName] = nil
                    self.questionSteps[r.fileName] = nil
                    AgentActions.focus(s, requests: self.requests)
                }))
        }
        var q = s.label
        if q.hasPrefix("❓") { q.removeFirst(); q = q.trimmingCharacters(in: .whitespaces) }
        if q.isEmpty { q = "\(s.agent.name) has a question" }
        return card(IslandQuestionView(
            question: q,
            deferTitle: deferTitle(for: s),
            width: width
        ) { [weak self] in
            guard let self else { return }
            AgentActions.focus(s, requests: self.requests)
        })
    }

    /// Echo the choice in the pill — "✓ Allowed" — for a beat, then go back to
    /// reporting. Defer skips the flash: the hand-off itself is the feedback.
    private func flashAnswer(_ behavior: String, plan: Bool = false) {
        wantsExpanded = false
        collapseWork?.cancel()
        expandWork?.cancel()
        let green = NSColor(srgbRed: 0.35, green: 0.85, blue: 0.45, alpha: 1)
        switch behavior {
        // Honest tense for plans: what went out is the dialog keystroke, and
        // the session's own dialog has the last word.
        case "allow":  flash = (plan ? "Approving plan…" : "✓ Allowed", green)
        case "always": flash = ("✓ Always allowed", green)
        case "answer": flash = ("✓ Answered", green)
        case "deny" where plan:
            // Sending a plan back is a neutral outcome, not a refusal.
            flash = ("✎ Planning on", NSColor.white.withAlphaComponent(0.85))
        case "denyNote" where plan:
            flash = ("✎ Sent back", NSColor.white.withAlphaComponent(0.85))
        case "deny":   flash = ("✕ Denied", NSColor(srgbRed: 1, green: 0.45, blue: 0.42, alpha: 1))
        // Still a refusal, but one that told the agent where to go instead.
        case "denyNote": flash = ("✕ Denied · told it", NSColor(srgbRed: 1, green: 0.45, blue: 0.42, alpha: 1))
        default:       flash = nil
        }
        rebuild(animated: true)
        guard flash != nil else { return }
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flash = nil
            self.rebuild(animated: true)
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    func more(_ n: Int) -> NSView {
        let l = NSTextField(labelWithString: "+\(n) more session\(n == 1 ? "" : "s")")
        l.font = .systemFont(ofSize: 11)
        l.textColor = NSColor.white.withAlphaComponent(0.45)
        return l
    }

    private func emptyRow(width: CGFloat) -> NSView {
        let firstRun = EmptyState.firstRun
        let l = NSTextField(labelWithString: EmptyState.title(firstRun: firstRun))
        l.font = .systemFont(ofSize: 12)
        l.textColor = NSColor.white.withAlphaComponent(0.45)
        guard let hint = EmptyState.hint(firstRun: firstRun) else { return l }
        let h = NSTextField(wrappingLabelWithString: hint)
        h.font = .systemFont(ofSize: 11)
        h.textColor = NSColor.white.withAlphaComponent(0.35)
        h.preferredMaxLayoutWidth = width
        let stack = NSStackView(views: [l, h])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        return stack
    }

    func click(_ s: Session) {
        AgentActions.focus(s, requests: requests)
    }
}
