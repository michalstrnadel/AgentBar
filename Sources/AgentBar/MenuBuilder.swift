import Cocoa

/// Builds the dropdown menu from a session snapshot. Stateless: every open rebuilds.
enum MenuBuilder {
    static func populate(_ menu: NSMenu, sessions: [Session], requests: [ApprovalRequest],
                         controller: StatusItemController) {
        menu.removeAllItems()

        // Sessions
        menu.addItem(header("Sessions"))
        if sessions.isEmpty {
            let none = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for s in sessions {
                let item = NSMenuItem(title: "", action: #selector(StatusItemController.sessionRowClicked(_:)),
                                      keyEquivalent: "")
                item.target = controller
                item.representedObject = s
                item.attributedTitle = rowTitle(s)
                item.toolTip = rowToolTip(s)
                let sessionRequests = requests.filter { $0.sessionId == s.id }
                if s.state == .permission {
                    if !sessionRequests.isEmpty {
                        // Row click defers to the session's own UI; actions live right below.
                        menu.addItem(item)
                        addInlineApproval(to: menu, for: s, requests: sessionRequests,
                                          controller: controller)
                        continue
                    }
                    // No request file (non-Claude agent). With a keystroke backend
                    // the row gets a Claude-style inline strip; otherwise an info
                    // submenu is all we can offer.
                    if Agent.byID(s.agentID).approveKeys != nil {
                        menu.addItem(item)
                        addKeystrokeApproval(to: menu, for: s, controller: controller)
                        continue
                    }
                    item.submenu = keystrokeSubmenu(for: s, controller: controller)
                }
                if s.state == .question,
                   let r = sessionRequests.first(where: { $0.questions != nil }),
                   let qs = r.questions {
                    menu.addItem(item)
                    addInlineQuestion(to: menu, for: s, request: r, questions: qs,
                                      controller: controller)
                    continue
                }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        // Open
        let openParent = NSMenuItem(title: "Open", action: nil, keyEquivalent: "")
        openParent.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
        let openSub = NSMenu()
        openSub.delegate = controller // report open/close so live refresh can hold off
        for agent in Agent.all {
            let item = NSMenuItem(title: agent.name, action: #selector(StatusItemController.openAgentClicked(_:)),
                                  keyEquivalent: "")
            item.target = controller
            item.representedObject = agent
            item.image = menuMark(for: agent)
            openSub.addItem(item)
        }
        openSub.addItem(.separator())
        // Terminal ▸ every installed terminal; the checkmarked one is what Codex/Copilot
        // open into. Clicking opens it and remembers it as the preferred terminal.
        let termParent = NSMenuItem(title: "Terminal", action: nil, keyEquivalent: "")
        let termSub = NSMenu()
        termSub.delegate = controller
        let preferred = TerminalApp.preferred(sessions: sessions)
        for terminal in TerminalApp.installed {
            let item = NSMenuItem(title: terminal.name,
                                  action: #selector(StatusItemController.openTerminalClicked(_:)),
                                  keyEquivalent: "")
            item.target = controller
            item.representedObject = terminal
            item.state = terminal.bundleID == preferred.bundleID ? .on : .off
            termSub.addItem(item)
        }
        termParent.submenu = termSub
        openSub.addItem(termParent)
        openParent.submenu = openSub
        menu.addItem(openParent)

        // Color
        let colorParent = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorParent.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        let colorSub = NSMenu()
        colorSub.delegate = controller
        for (title, system) in [("Color", false), ("System", true)] {
            let item = NSMenuItem(title: title, action: #selector(StatusItemController.chooseColor(_:)),
                                  keyEquivalent: "")
            item.target = controller
            item.representedObject = system
            item.state = controller.systemColor == system ? .on : .off
            colorSub.addItem(item)
        }
        colorParent.submenu = colorSub
        menu.addItem(colorParent)

        // One-click mute/unmute; volume and the cue details live in Settings.
        let sounds = NSMenuItem(title: "Sounds",
                                action: #selector(StatusItemController.toggleSounds(_:)),
                                keyEquivalent: "")
        sounds.identifier = NSUserInterfaceItemIdentifier("soundsRow")
        sounds.target = controller
        sounds.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)
        configureSoundsRow(sounds)
        menu.addItem(sounds)

        // Where AgentBar shows itself (menu bar / island / both), plus the first-run
        // blurb — the same window, reachable again.
        let appearance = NSMenuItem(title: "Appearance…",
                                    action: #selector(StatusItemController.openWelcome(_:)),
                                    keyEquivalent: "")
        appearance.target = controller
        appearance.image = NSImage(systemSymbolName: "macwindow.on.rectangle",
                                   accessibilityDescription: nil)
        menu.addItem(appearance)

        // Opt-in global Allow/Deny shortcut; the row opens Settings (enable + rebind).
        let shortcut = NSMenuItem(title: "Global Allow / Deny shortcut…",
                                  action: #selector(StatusItemController.openShortcutSettings(_:)),
                                  keyEquivalent: "")
        shortcut.identifier = NSUserInterfaceItemIdentifier("shortcutRow")
        shortcut.target = controller
        shortcut.image = NSImage(systemSymbolName: "command", accessibilityDescription: nil)
        configureShortcutRow(shortcut, controller: controller)
        menu.addItem(shortcut)

        menu.addItem(.separator())
        menu.addItem(updateRow(controller))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// One row that is the whole update UI: check → checking → result / install.
    /// The current version rides along as a badge, so no separate "Version" row.
    /// Carries an icon so the bottom section (Quit gets a system icon on new macOS)
    /// keeps one consistent icon gutter instead of ragged indents.
    private static func updateRow(_ controller: StatusItemController) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("updateRow")
        configureUpdateRow(item, controller: controller)
        return item
    }

    /// (Re)applies the whole update-row appearance — also called by `updateInPlace`
    /// on the live item, so every field it can set is reset first.
    private static func configureUpdateRow(_ item: NSMenuItem, controller: StatusItemController) {
        item.attributedTitle = nil
        item.action = nil
        item.target = nil
        item.toolTip = nil
        var badge = appVersion
        var symbol = "arrow.triangle.2.circlepath"
        switch UpdateChecker.shared.status {
        case .idle:
            item.title = "Check for Updates…"
            item.action = #selector(StatusItemController.checkForUpdatesClicked(_:))
            item.target = controller
        case .checking:
            item.title = "Checking for updates…"
        case .upToDate:
            item.title = "Up to date"
            symbol = "checkmark.circle"
        case .available(let v):
            item.attributedTitle = NSAttributedString(
                string: "Update to \(v) — Install & Relaunch",
                attributes: [.foregroundColor: NSColor.controlAccentColor,
                             .font: NSFont.menuFont(ofSize: 0)])
            item.action = #selector(StatusItemController.installUpdateClicked(_:))
            item.target = controller
            symbol = "arrow.down.circle.fill"
            badge = ""
        case .downloading(let v):
            item.title = "Downloading \(v)…"
            symbol = "arrow.down.circle"
            badge = ""
        case .failed(let reason):
            item.title = "\(reason) — Retry"
            item.action = #selector(StatusItemController.checkForUpdatesClicked(_:))
            item.target = controller
            symbol = "exclamationmark.arrow.triangle.2.circlepath"
        }
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if #available(macOS 14.0, *) {
            item.badge = badge.isEmpty ? nil : NSMenuItemBadge(string: badge)
        } else if !badge.isEmpty {
            item.toolTip = "AgentBar \(badge)"
        }
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    private static func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return .sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// "● project · branch   AGENT" — dot colored by state, agent tag dimmed.
    private static func rowTitle(_ s: Session) -> NSAttributedString {
        let agent = Agent.byID(s.agentID)
        let dotColor: NSColor
        switch s.state {
        case .permission:      dotColor = IconRenderer.amberDot
        case .question:        dotColor = IconRenderer.questionDot
        case .thinking, .tool: dotColor = agent.brand
        case .idle, .done:     dotColor = .tertiaryLabelColor
        }

        let title = NSMutableAttributedString()
        title.append(NSAttributedString(string: "● ", attributes: [
            .foregroundColor: dotColor,
            .font: NSFont.menuFont(ofSize: 11),
        ]))
        var name = s.project.isEmpty ? "session" : s.project
        if let branch = s.gitBranch { name += " · \(branch)" }
        title.append(NSAttributedString(string: name, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
        ]))
        var sub = s.state == .permission ? "  needs approval" : (s.label.isEmpty ? "" : "  \(s.label)")
        // Done rows say WHAT finished. 60 chars keeps the menu from ballooning;
        // the tooltip carries the full line.
        if sub.isEmpty, s.state == .done || s.state == .idle, !s.recap.isEmpty {
            sub = "  " + String(s.recap.prefix(60)) + (s.recap.count > 60 ? "…" : "")
        }
        if !sub.isEmpty {
            title.append(NSAttributedString(string: sub, attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.menuFont(ofSize: 11),
            ]))
        }
        title.append(NSAttributedString(string: "   \(agent.name.uppercased())", attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
        ]))
        return title
    }

    /// cwd, plus the last turn's recap when the writer carries one.
    private static func rowToolTip(_ s: Session) -> String {
        s.recap.isEmpty ? s.cwd
            : "\(s.cwd)\n\n\(Agent.byID(s.agentID).name): \(s.recap)"
    }

    /// Small resting mark used as the item icon in the Open submenu. Every mark is
    /// tight-trimmed to its glyph, normalized to one cap height, then centered on
    /// one shared canvas (sized by the widest glyph) — identical image bounds give
    /// every row the same gutter and title inset, with no per-glyph jitter. Codex
    /// and Copilot use their clean dot-free glyph (the bar sprite carries a
    /// dot-matrix); Cursor and Gemini knock out their full-res app icon so both
    /// read at the same solid weight as the mascots.
    private static let markCapHeight: CGFloat = 13

    private static let menuMarks: [String: NSImage] = {
        let glyphs: [(String, NSImage)] = Agent.all.map { agent in
            let template: NSImage
            switch agent.id {
            case "codex":
                template = IconRenderer.decode(codexMascotMarkPNG).map {
                    IconRenderer.solidTemplate(IconRenderer.trim($0))
                } ?? trimmedTemplate(for: agent)
            case "copilot":
                template = IconRenderer.decode(copilotMascotMarkPNG).map {
                    IconRenderer.adaptiveTemplate(IconRenderer.trim($0))
                } ?? trimmedTemplate(for: agent)
            case "cursor":
                template = IconRenderer.decode(cursorLogoPNG).map {
                    IconRenderer.adaptiveTemplate(IconRenderer.trim($0), knockout: true)
                } ?? trimmedTemplate(for: agent)
            case "gemini":
                template = IconRenderer.decode(geminiLogoPNG).map {
                    IconRenderer.adaptiveTemplate(IconRenderer.trim($0), knockout: true)
                } ?? trimmedTemplate(for: agent)
            default:
                template = trimmedTemplate(for: agent)
            }
            let img = template.copy() as! NSImage
            let scale = markCapHeight / max(img.size.height, 1)
            img.size = NSSize(width: (img.size.width * scale).rounded(), height: markCapHeight)
            return (agent.id, img)
        }
        let boxWidth = glyphs.map { $0.1.size.width }.max() ?? markCapHeight
        return Dictionary(uniqueKeysWithValues: glyphs.map { id, glyph in
            let out = NSImage(size: NSSize(width: boxWidth, height: markCapHeight))
            out.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            glyph.draw(in: NSRect(x: ((boxWidth - glyph.size.width) / 2).rounded(),
                                  y: 0, width: glyph.size.width, height: markCapHeight))
            out.unlockFocus()
            out.isTemplate = true
            return (id, out)
        })
    }()

    private static func menuMark(for agent: Agent) -> NSImage {
        menuMarks[agent.id] ?? trimmedTemplate(for: agent)
    }

    /// Resting template of an agent's sprite, tight-trimmed and re-flagged as template.
    private static func trimmedTemplate(for agent: Agent) -> NSImage {
        let t = IconRenderer.trim(IconRenderer.shared.sprite(for: agent).restingTemplate)
        t.isTemplate = true
        return t
    }

    /// The pending command and an Allow/Always/Deny/defer button strip inserted
    /// directly under the session row — no second navigation level.
    private static func addInlineApproval(to menu: NSMenu, for s: Session,
                                          requests: [ApprovalRequest],
                                          controller: StatusItemController) {
        for r in requests {
            let tag = "req:\(r.fileName)" // lets updateInPlace find a strip's rows
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

            let buttons = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            buttons.view = ApprovalButtonsRow(
                hasRule: r.ruleDescription != nil,
                ruleToolTip: r.ruleDescription.map { "Always allow \($0)" },
                deferTitle: s.entrypoint == "claude-desktop" ? "⧉ Claude app" : "⌨ Terminal",
                onChoose: { [weak controller] behavior in
                    controller?.answer(ApprovalAction(request: r, behavior: behavior, session: s))
                })
            buttons.representedObject = tag
            menu.addItem(buttons)
        }
    }

    /// The pending question inserted directly under the session row. The common
    /// case — one question, pick one option — answers on click, like the approval
    /// strip. multiSelect and multi-question calls need toggles a menu can't hold
    /// open, so they point at the island card instead.
    private static func addInlineQuestion(to menu: NSMenu, for s: Session,
                                          request r: ApprovalRequest,
                                          questions qs: [ApprovalRequest.Context.Question],
                                          controller: StatusItemController) {
        let tag = "req:\(r.fileName)"
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
            // open, so complex calls answer on the island — or in the terminal
            // when there is no island to point at.
            let surface = Presentation.current.showsIsland ? "answer on the island"
                                                           : "answer in the terminal"
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

    // MARK: - Live refresh of an open menu

    /// Reconcile an OPEN menu with fresh state without adding or removing rows.
    /// An open NSMenu window never shrinks — removing rows leaves a blank band
    /// hanging at the bottom until the menu closes — so surviving rows are
    /// updated in place and vanished ones are dimmed (`ended` sessions, muted
    /// approval strips); the next open rebuilds cleanly. Returns false when
    /// fresh state needs rows that aren't displayed (new session or request):
    /// growth needs a real populate, which an open menu handles fine.
    /// The request an item belongs to, whichever way it carries the tag: summary
    /// lines and card views hold a "req:<file>" string in representedObject; a
    /// question's option/escape items need representedObject for their payload,
    /// so their tag rides in the identifier instead.
    private static func requestTag(_ item: NSMenuItem) -> String? {
        if let tag = item.representedObject as? String, tag.hasPrefix("req:") {
            return String(tag.dropFirst(4))
        }
        if let id = item.identifier?.rawValue, id.hasPrefix("req:") {
            return String(id.dropFirst(4))
        }
        return nil
    }

    static func updateInPlace(_ menu: NSMenu, sessions: [Session], requests: [ApprovalRequest],
                              controller: StatusItemController) -> Bool {
        var displayedSessions = Set<String>()
        var displayedRequests = Set<String>()
        for item in menu.items {
            if let tag = requestTag(item) { displayedRequests.insert(tag); continue }
            if let s = item.representedObject as? Session { displayedSessions.insert(s.id) }
        }
        guard Set(sessions.map(\.id)).isSubset(of: displayedSessions),
              Set(requests.map(\.fileName)).isSubset(of: displayedRequests) else { return false }

        let live = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let liveRequests = Set(requests.map(\.fileName))
        for item in menu.items {
            // Request-tagged rows first: a question's escape item also carries a
            // Session and must not be rewritten into a second session row.
            if let tag = requestTag(item) {
                if !liveRequests.contains(tag) { mute(item) }
                continue
            }
            if let s = item.representedObject as? Session {
                if let updated = live[s.id] {
                    item.representedObject = updated
                    item.attributedTitle = rowTitle(updated)
                    item.toolTip = rowToolTip(updated)
                    // Keystroke fallback appears/disappears with the permission state.
                    let hasStrip = requests.contains { $0.sessionId == updated.id }
                    item.submenu = (updated.state == .permission && !hasStrip)
                        ? keystrokeSubmenu(for: updated, controller: controller) : nil
                } else {
                    item.attributedTitle = endedRowTitle(s)
                    item.submenu = nil
                }
            } else if item.identifier?.rawValue == "updateRow" {
                configureUpdateRow(item, controller: controller)
            } else if item.identifier?.rawValue == "shortcutRow" {
                configureShortcutRow(item, controller: controller)
            } else if item.identifier?.rawValue == "soundsRow" {
                configureSoundsRow(item)
            }
        }
        return true
    }

    static func configureSoundsRow(_ item: NSMenuItem) {
        let on = SoundCenter.enabled
        item.state = on ? .on : .off
        item.toolTip = on
            ? "Cues when a session needs approval, asks a question or finishes — volume in Settings"
            : "Off — click for a soft cue when a session needs approval, asks or finishes"
    }

    static func configureShortcutRow(_ item: NSMenuItem, controller: StatusItemController) {
        item.state = controller.approvalShortcutEnabled ? .on : .off
        item.toolTip = controller.approvalShortcutEnabled
            ? "\(KeyCombo.allow.display) allow · \(KeyCombo.deny.display) deny the newest pending request — click to configure"
            : "Off — click to enable and pick the keys"
    }

    /// A vanished approval strip: fade the custom views and disarm their buttons
    /// so an already-answered request can't be answered twice; the summary line
    /// dims to match, and clickable rows (question options) lose their action.
    private static func mute(_ item: NSMenuItem) {
        item.action = nil
        if let view = item.view {
            guard view.alphaValue > 0.55 else { return } // already muted
            view.alphaValue = 0.5
            disableControls(in: view)
        } else if let title = item.attributedTitle {
            let dimmed = NSMutableAttributedString(attributedString: title)
            dimmed.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                                range: NSRange(location: 0, length: dimmed.length))
            item.attributedTitle = dimmed
        }
    }

    private static func disableControls(in view: NSView) {
        for sub in view.subviews {
            (sub as? NSControl)?.isEnabled = false
            disableControls(in: sub)
        }
    }

    /// Row for a session that ended while the menu was open: dimmed, tagged, still
    /// clickable (focuses the terminal it lived in).
    private static func endedRowTitle(_ s: Session) -> NSAttributedString {
        let agent = Agent.byID(s.agentID)
        let title = NSMutableAttributedString()
        title.append(NSAttributedString(string: "● ", attributes: [
            .foregroundColor: NSColor.quaternaryLabelColor,
            .font: NSFont.menuFont(ofSize: 11),
        ]))
        var name = s.project.isEmpty ? "session" : s.project
        if let branch = s.gitBranch { name += " · \(branch)" }
        title.append(NSAttributedString(string: name, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.menuFont(ofSize: 0),
        ]))
        title.append(NSAttributedString(string: "  ended", attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.menuFont(ofSize: 11),
        ]))
        title.append(NSAttributedString(string: "   \(agent.name.uppercased())", attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
        ]))
        return title
    }

    /// Claude-look button strip for agents whose approval lives in their own UI
    /// (Antigravity dialog, Codex/Copilot terminal prompt): Allow submits the
    /// preselected option via keystroke; the second button jumps to the prompt.
    private static func addKeystrokeApproval(to menu: NSMenu, for s: Session,
                                             controller: StatusItemController) {
        let agent = Agent.byID(s.agentID)
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

    private static func keystrokeSubmenu(for s: Session, controller: StatusItemController) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = controller
        let agent = Agent.byID(s.agentID)
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

/// Payload describing one approval decision (request + behavior + owning session).
final class ApprovalAction: NSObject {
    let request: ApprovalRequest
    let behavior: String   // "allow" | "always" | "deny" | "defer"
    let session: Session
    init(request: ApprovalRequest, behavior: String, session: Session) {
        self.request = request
        self.behavior = behavior
        self.session = session
    }
}

/// Payload for one clicked question option: the chosen labels, per question.
final class QuestionAnswerAction: NSObject {
    let request: ApprovalRequest
    let labels: [[String]]
    let session: Session
    init(request: ApprovalRequest, labels: [[String]], session: Session) {
        self.request = request
        self.labels = labels
        self.session = session
    }
}
