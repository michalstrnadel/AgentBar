import Cocoa

/// What a waiting session gets under its row: the approval strip, the question
/// options, or — for agents that write no request file — the keystroke strip.
extension MenuBuilder {
    /// The pending command and an Allow/Always/Deny/defer button strip inserted
    /// directly under the session row — no second navigation level.
    static func addInlineApproval(to menu: NSMenu, for s: Session,
                                          requests: [ApprovalRequest],
                                          allRequests: [ApprovalRequest] = [],
                                          allSessions: [Session] = [],
                                          controller: StatusItemController) {
        for r in requests {
            let tag = "req:\(requestKey(r))" // lets updateInPlace find a strip's rows
            let what = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            what.isEnabled = false
            what.toolTip = r.toolInputPretty
            what.representedObject = tag
            what.attributedTitle = NSAttributedString(string: "      \(r.display)", attributes: [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            menu.addItem(what)

            // Inline detail: the mini-diff / full command, when the hook supplied it.
            if let context = r.context {
                let ctx = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                ctx.view = ApprovalContextView(context: context)
                ctx.representedObject = tag
                menu.addItem(ctx)
            }

            // What you did about this exact prompt before, at the moment you are
            // deciding again — the only place that fact is worth anything.
            let past = DecisionLedger.summary(shape: DecisionLedger.shape(of: r), cwd: s.cwd,
                                              in: DecisionLedger.cached())
            let promote = DecisionLedger.shouldPromoteAlways(past, hasRule: r.ruleDescription != nil)
            // Every time, the same answer, enough times to be a habit: the count
            // becomes an offer to write it down. Offered, not taken — the click
            // opens a sheet that shows what the rule would and would not answer,
            // and the rule exists only once the person presses Add.
            let offer = plan(r) ? nil : DecisionLedger.shouldOfferRule(past)
            if var hint = DecisionLedger.hint(past) {
                // Enough repeats and never once refused: say that the button beside
                // this line would end the asking. Saying, not pressing — a count is
                // not consent. Nothing on this card answers anything by itself; a
                // rule does, and only one you wrote and can read back.
                if promote { hint += " — ✓ Always stops the asking" }
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.representedObject = tag
                item.attributedTitle = NSAttributedString(string: "      \(hint)", attributes: [
                    .font: NSFont.menuFont(ofSize: 11),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ])
                menu.addItem(item)
            }
            if let offer {
                let item = NSMenuItem(title: "", action: #selector(StatusItemController.makeRule(_:)),
                                      keyEquivalent: "")
                item.target = controller
                item.representedObject = tag
                // The request this offer belongs to. `representedObject` is spoken
                // for by the row tag `updateInPlace` tracks, so the payload rides
                // on the identifier instead of inventing a second tracking scheme.
                item.identifier = NSUserInterfaceItemIdentifier("\(offer)|\(r.fileName)")
                item.attributedTitle = NSAttributedString(
                    string: "      Always \(offer) this here…",
                    attributes: [.font: NSFont.menuFont(ofSize: 11),
                                 .foregroundColor: NSColor.controlAccentColor])
                item.toolTip = "Writes a rule of your own. It answers this prompt and nothing "
                    + "wider, and every time it does the approval history says so."
                menu.addItem(item)
            }

            // The same request waiting in other sessions: one click for all of them
            // that are on screen now (`ApprovalBatch`). The identities ride on the
            // identifier, so a request that arrives later is never part of the click.
            let alike = ApprovalBatch.alike(r, in: allRequests, cwd: { q in
                allSessions.first { $0.id == q.sessionId }?.cwd ?? "" })
            if alike.count > 1, !plan(r) {
                let item = NSMenuItem(title: "", action: #selector(StatusItemController.allowAllAlike(_:)),
                                      keyEquivalent: "")
                item.target = controller
                item.representedObject = tag
                item.identifier = NSUserInterfaceItemIdentifier(alike.map(\.identity).joined(separator: ","))
                item.attributedTitle = NSAttributedString(
                    string: "      \(ApprovalBatch.title(alike.count)) — the same request in \(alike.count) sessions",
                    attributes: [.font: NSFont.menuFont(ofSize: 11),
                                 .foregroundColor: NSColor.controlAccentColor])
                item.toolTip = "Each one is written to the approval history as your own answer. "
                    + "A request that arrives after this menu opened is not included."
                menu.addItem(item)
            }

            let buttons = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let deferTitle = s.entrypoint == "claude-desktop" ? "⧉ Claude app" : "⌨ Terminal"
            let onChoose: (String) -> Void = { [weak controller] behavior in
                controller?.answer(ApprovalAction(request: r, behavior: behavior, session: s))
            }
            if r.isPlanRequest {
                // A plan is approved in the session's own dialog (the hook can't
                // carry the mode choice), so Approve is a keystroke — labeled
                // the way keystroke approvals are labeled everywhere else.
                buttons.view = ApprovalButtonsRow(buttons: [
                    ("✓ Approve plan", "allow",
                     "Focuses the session and selects “manually approve edits” in the plan dialog"),
                    ("✎ Keep planning", "deny",
                     "Tells Claude to refine the plan before making changes"),
                    (deferTitle, "defer", "Review in \(deferTitle.dropFirst(2)) instead"),
                ], onChoose: onChoose)
            } else {
                buttons.view = ApprovalButtonsRow(
                    hasRule: r.ruleDescription != nil,
                    ruleToolTip: r.ruleDescription.map { "Always allow \($0)" },
                    deferTitle: deferTitle,
                    promoteAlways: promote,
                    onChoose: onChoose)
            }
            buttons.representedObject = tag
            menu.addItem(buttons)
        }
    }

    /// A plan is approved in its own dialog, so there is no rule to offer for one.
    private static func plan(_ r: ApprovalRequest) -> Bool { r.isPlanRequest }

    /// The pending question inserted directly under the session row. The common
    /// case — one question, pick one option — answers on click, like the approval
    /// strip. multiSelect and multi-question calls need toggles a menu can't hold
    /// open, so they point at the island card instead.
    static func addInlineQuestion(to menu: NSMenu, for s: Session,
                                          request r: ApprovalRequest,
                                          questions qs: [ApprovalRequest.Context.Question],
                                          controller: StatusItemController) {
        let tag = "req:\(requestKey(r))"
        let simple = qs.count == 1 && !qs[0].multiSelect

        let what = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        what.isEnabled = false
        what.toolTip = r.toolInputPretty
        what.representedObject = tag
        what.attributedTitle = NSAttributedString(string: "      ❓ \(qs[0].question)", attributes: [
            .font: NSFont.menuFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        menu.addItem(what)

        if simple {
            for opt in qs[0].options {
                let item = NSMenuItem(title: "",
                                      action: #selector(StatusItemController.questionOptionClicked(_:)),
                                      keyEquivalent: "")
                item.target = controller
                item.identifier = NSUserInterfaceItemIdentifier(tag)
                item.representedObject = QuestionAnswerAction(request: r, labels: [[opt.label]],
                                                              session: s)
                let title = NSMutableAttributedString(string: "      \(opt.label)", attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                ])
                if !opt.description.isEmpty {
                    title.append(NSAttributedString(string: "  \(opt.description)", attributes: [
                        .font: NSFont.menuFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
                }
                item.attributedTitle = title
                menu.addItem(item)
            }
        } else {
            let hint = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            hint.representedObject = tag
            // Point at a surface the user actually has: menus can't hold toggles
            // open, so complex calls answer on the island — or wherever the
            // session's own wizard lives when there is no island to point at.
            let surface = Presentation.current.showsIsland ? "answer on the island"
                : (s.entrypoint == "claude-desktop" ? "answer in Claude" : "answer in the terminal")
            hint.attributedTitle = NSAttributedString(
                string: "      \(qs.count > 1 ? "\(qs.count) questions" : "Pick several") — \(surface)",
                attributes: [.font: NSFont.menuFont(ofSize: 11),
                             .foregroundColor: NSColor.tertiaryLabelColor])
            menu.addItem(hint)
        }

        // The wizard is already on the terminal's screen; this just retires the
        // card here and takes the user to it.
        let escape = NSMenuItem(title: s.entrypoint == "claude-desktop"
                                ? "      ⧉ Answer in Claude" : "      ⌨ Answer in terminal",
                                action: #selector(StatusItemController.sessionRowClicked(_:)),
                                keyEquivalent: "")
        escape.target = controller
        escape.identifier = NSUserInterfaceItemIdentifier(tag)
        escape.representedObject = s
        menu.addItem(escape)
    }

    /// Claude-look button strip for agents whose approval lives in their own UI
    /// (Antigravity dialog, Codex/Copilot terminal prompt): Allow submits the
    /// preselected option via keystroke; the second button jumps to the prompt.
    static func addKeystrokeApproval(to menu: NSMenu, for s: Session,
                                             controller: StatusItemController) {
        let agent = s.agent
        let target = s.entrypoint == "antigravity-app" ? "⧉ \(agent.name)" : "⌨ Terminal"
        let specs: [(title: String, behavior: String, toolTip: String?)] =
            KeystrokeApprover.trusted
            ? [("✓ Allow", "allow",
                "Brings the prompt forward and submits its preselected option (sends ⏎)"),
               (target, "open", "Answer there yourself")]
            : [("Grant Accessibility…", "grant",
                "Needed to send the approval keystroke"),
               (target, "open", "Answer there yourself")]
        let buttons = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        buttons.view = ApprovalButtonsRow(buttons: specs) { [weak controller] behavior in
            controller?.keystrokeAnswer(behavior, session: s)
        }
        buttons.representedObject = "kstrip:\(s.id)" // not "req:" — refresh must not mute it
        menu.addItem(buttons)
    }

    static func keystrokeSubmenu(for s: Session, controller: StatusItemController) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = controller
        let agent = s.agent
        // Cowork puts the tool name in the label even though it writes no request
        // file — say what is being asked instead of only that we can't show it.
        let note = NSMenuItem(title: s.label.isEmpty
                              ? "Can't show the request for \(agent.name)"
                              : "Waiting on: \(s.label)",
                              action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
        if agent.approveKeys != nil {
            let target = s.entrypoint == "antigravity-app" ? agent.name : "terminal"
            let title = KeystrokeApprover.trusted
                ? "Approve in \(target) (sends keystroke)" : "Grant Accessibility…"
            let item = NSMenuItem(title: title,
                                  action: #selector(StatusItemController.keystrokeApproveClicked(_:)),
                                  keyEquivalent: "")
            item.target = controller
            item.representedObject = s
            menu.addItem(item)
        }
        // App-hosted sessions (Cowork) answer the prompt in the app, not a terminal.
        let hostedInApp = s.entrypoint == "claude-desktop" || s.entrypoint == "antigravity-app"
        let open = NSMenuItem(title: hostedInApp ? "Answer in \(agent.name)" : "Open in terminal",
                              action: #selector(StatusItemController.sessionRowClicked(_:)),
                              keyEquivalent: "")
        open.target = controller
        open.representedObject = s
        menu.addItem(open)
        return menu
    }
}
