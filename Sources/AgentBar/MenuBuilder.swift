import Cocoa

/// Builds the dropdown menu from a session snapshot. Stateless: every open rebuilds.
enum MenuBuilder {
    static func populate(_ menu: NSMenu, sessions: [Session], requests: [ApprovalRequest],
                         controller: StatusItemController) {
        menu.removeAllItems()

        // Sessions
        menu.addItem(header("Sessions"))
        if sessions.isEmpty {
            let firstRun = EmptyState.firstRun
            let none = NSMenuItem(title: EmptyState.title(firstRun: firstRun), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            if let hint = EmptyState.hint(firstRun: firstRun) {
                let line = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                line.isEnabled = false
                line.attributedTitle = NSAttributedString(string: wrapped(hint, width: 46), attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
                menu.addItem(line)
            }
        } else {
            for s in sessions {
                let item = NSMenuItem(title: "", action: #selector(StatusItemController.sessionRowClicked(_:)),
                                      keyEquivalent: "")
                item.target = controller
                item.representedObject = s
                // Drawn, not typeset: the same mark the Open submenu uses, and the
                // time and agent in aligned columns. `title` stays for type-select.
                let row = SessionRowView(session: s, mark: menuMark(for: s.agent))
                row.toolTip = rowToolTip(s)
                item.view = row
                item.title = SessionRowView.plainTitle(row.content)
                let sessionRequests = requests.filter { $0.sessionId == s.id }
                // Cloud rows get no approval affordances: there is no local hook a
                // keystroke or answer file could reach — the plain row (which opens
                // the session's URL) is the whole offer.
                if s.state == .permission, s.entrypoint != "cloud" {
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
                    if s.agent.approveKeys != nil {
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

        // What each provider has left: read from the CLIs' own local files, and —
        // only if that switch was turned on — from Claude's own account. Shown
        // while the data is fresh enough to be true, and absent otherwise.
        if let meters = UsageMeterView(readings: UsageCenter.shared.readings) {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.view = meters
            menu.addItem(item)
        }
        let today = todayRow(target: controller,
                             action: #selector(StatusItemController.openPastProject(_:)))
        today.submenu?.delegate = controller // hold live refresh while it is open
        menu.addItem(today)
        menu.addItem(.separator())

        // Start a task, rather than an agent: the launcher, reachable without the
        // global chord — a keystroke nobody has heard of is a feature nobody has.
        let newTask = NSMenuItem(title: "New task…",
                                 action: #selector(StatusItemController.openLauncher(_:)),
                                 keyEquivalent: "")
        newTask.target = controller
        newTask.image = NSImage(systemSymbolName: "plus.bubble", accessibilityDescription: nil)
        if LauncherPanel.shortcutEnabled { newTask.toolTip = KeyCombo.launch.display }
        menu.addItem(newTask)

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

        // Carries the verdict of the last background pass rather than only opening
        // Settings: a silent failure that waits to be looked for is still silent.
        let doctor = NSMenuItem(title: "",
                                action: #selector(StatusItemController.openDiagnostics(_:)),
                                keyEquivalent: "")
        doctor.identifier = NSUserInterfaceItemIdentifier("diagnosticsRow")
        doctor.target = controller
        configureDiagnosticsRow(doctor)
        menu.addItem(doctor)

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

    /// What finished today, as one line with the sessions behind it.
    ///
    /// The menu answers "what is happening"; this is the only place AgentBar answers
    /// "what happened", and it stays a menu row rather than becoming a window —
    /// rule 2 allows exactly two surfaces, and a dashboard is not one of them.
    ///
    /// Read fresh on every open. A digest recomputed when someone asks for it is
    /// cheap; a digest kept in sync all day is a store nobody needed.
    ///
    /// Takes its target rather than assuming the status item: in island-only mode
    /// there is no menu bar item at all, and a digest only one of the two surfaces
    /// can reach is half a feature. The island's overflow menu uses the same row.
    static func todayRow(target: AnyObject?, action: Selector?) -> NSMenuItem {
        let (summary, entries) = HistoryDigest.today(HistoryStore.read())
        let item = NSMenuItem(title: "Today", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        let title = NSMutableAttributedString(string: "Today  ")
        title.append(dim(HistoryDigest.headline(summary)))
        item.attributedTitle = title
        guard !entries.isEmpty else {
            item.isEnabled = false
            item.toolTip = "Sessions are recorded as they end; this fills up as the day goes on."
            return item
        }
        let sub = NSMenu()
        // Enough to read at a glance, not a log. The rest is in `agentbar history`.
        for e in entries.prefix(12) {
            let row = NSMenuItem(title: "", action: action, keyEquivalent: "")
            row.target = target
            row.representedObject = e.cwd
            row.isEnabled = !e.cwd.isEmpty
            row.image = menuMark(for: e.resolvedAgent)
            row.attributedTitle = e.failed
                ? NSAttributedString(string: HistoryDigest.line(e),
                                     attributes: [.foregroundColor: NSColor.systemRed])
                : NSAttributedString(string: HistoryDigest.line(e))
            row.toolTip = e.cwd.isEmpty ? nil : "Open \(e.cwd)"
            sub.addItem(row)
        }
        if entries.count > 12 {
            let more = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            more.isEnabled = false
            more.attributedTitle = dim("…and \(entries.count - 12) more — `agentbar history`")
            sub.addItem(more)
        }
        // The other half of the day. Everything above is how long the machine
        // worked; this is how long it waited for you, which is the half nothing
        // else on the machine is standing in the right place to measure.
        if let waiting = waitingLine() {
            sub.addItem(.separator())
            let row = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            row.isEnabled = false
            row.attributedTitle = dim(waiting)
            sub.addItem(row)
        }
        item.submenu = sub
        return item
    }

    /// "18 answered · 3 by your rules · they waited 34m on you" — nil on a day with
    /// none, because a zero here is an absence and not a result.
    ///
    /// The two counts are kept apart rather than added up. "18 answered" that
    /// quietly included six a rule made would be the wrong number in the one place
    /// somebody would repeat it, and how much of a day AgentBar handled without
    /// asking is exactly the thing a person should be able to watch.
    static func waitingLine(now: Date = Date(), calendar: Calendar = .current) -> String? {
        let start = calendar.startOfDay(for: now).timeIntervalSince1970
        let records = DecisionLedger.cached()
        let day = DecisionLedger.waiting(in: records, since: start,
                                         until: now.timeIntervalSince1970)
        let byRules = DecisionLedger.byRules(in: records, since: start,
                                             until: now.timeIntervalSince1970)
        guard day.answered > 0 || byRules > 0 else { return nil }
        var parts: [String] = []
        if day.answered > 0 { parts.append("\(day.answered) answered") }
        if byRules > 0 { parts.append("\(byRules) by your rules") }
        var text = parts.joined(separator: " · ")
        if day.waited >= 60 {
            text += " · they waited \(HistoryDigest.duration(day.waited)) on you"
        }
        return text
    }

    private static func dim(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }

    /// Resets every field it sets — `updateInPlace` reuses the item, so a value left
    /// over from the healthy state would stick around after a failure appears.
    static func configureDiagnosticsRow(_ item: NSMenuItem) {
        let broken = Diagnostics.failures
        item.attributedTitle = nil
        item.title = broken == 0
            ? "Diagnostics…"
            : "Diagnostics — \(broken) problem\(broken == 1 ? "" : "s")…"
        item.image = NSImage(
            systemSymbolName: broken == 0 ? "stethoscope" : "exclamationmark.triangle",
            accessibilityDescription: nil)
        item.toolTip = broken == 0
            ? "Check that every agent's hooks are wired and working."
            : "Something is stopping an agent from reporting. Open for the details and the fix."
    }

    /// One row that is the whole update UI: check → checking → result / install.
    /// The current version rides along as a badge, so no separate "Version" row.
    /// Carries an icon so the bottom section (Quit gets a system icon on new macOS)
    /// keeps one consistent icon gutter instead of ragged indents.
    private static func updateRow(_ controller: StatusItemController) -> NSMenuItem {
        updateRow(target: controller,
                  check: #selector(StatusItemController.checkForUpdatesClicked(_:)),
                  install: #selector(StatusItemController.installUpdateClicked(_:)))
    }

    /// The same row for any menu — the island's ⋯ menu is the only menu there is in
    /// Island-only mode, and a bare "Check for Updates…" there checked and then had
    /// nowhere to say what it found, so nobody on that mode could ever update.
    static func updateRow(target: AnyObject, check: Selector, install: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("updateRow")
        configureUpdateRow(item, target: target, check: check, install: install)
        return item
    }

    /// (Re)applies the whole update-row appearance — also called by `updateInPlace`
    /// on the live item, so every field it can set is reset first.
    private static func configureUpdateRow(_ item: NSMenuItem, controller: StatusItemController) {
        configureUpdateRow(item, target: controller,
                           check: #selector(StatusItemController.checkForUpdatesClicked(_:)),
                           install: #selector(StatusItemController.installUpdateClicked(_:)))
    }

    static func configureUpdateRow(_ item: NSMenuItem, target: AnyObject,
                                   check: Selector, install: Selector) {
        item.attributedTitle = nil
        item.action = nil
        item.target = nil
        item.toolTip = nil
        var badge = appVersion
        var symbol = "arrow.triangle.2.circlepath"
        switch UpdateChecker.shared.status {
        case .idle:
            item.title = "Check for Updates…"
            item.action = check
            item.target = target
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
            item.action = install
            item.target = target
            symbol = "arrow.down.circle.fill"
            badge = ""
        case .ready(let v):
            // Downloaded and verified, waiting for a quiet moment to install by
            // itself; the click is for whoever would rather not wait.
            item.attributedTitle = NSAttributedString(
                string: "Update to \(v) ready — Relaunch now",
                attributes: [.foregroundColor: NSColor.controlAccentColor,
                             .font: NSFont.menuFont(ofSize: 0)])
            item.action = install
            item.target = target
            item.toolTip = "Installs by itself once nothing is waiting on you "
                + "and you have been away for five minutes."
            symbol = "arrow.down.circle.fill"
            badge = ""
        case .downloading(let v):
            item.title = "Downloading \(v)…"
            symbol = "arrow.down.circle"
            badge = ""
        case .failed(let reason):
            item.title = "\(reason) — Retry"
            item.action = check
            item.target = target
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

    /// Greedy word wrap for a disabled menu line: an NSMenuItem title never wraps
    /// by itself, it widens the whole menu to fit.
    static func wrapped(_ text: String, width: Int) -> String {
        var lines: [String] = [], line = ""
        for word in text.split(separator: " ") {
            if !line.isEmpty, line.count + 1 + word.count > width {
                lines.append(line); line = ""
            }
            line += (line.isEmpty ? "" : " ") + word
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }

    private static func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return .sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// cwd, plus the last turn's recap when the writer carries one.
    private static func rowToolTip(_ s: Session) -> String {
        s.recap.isEmpty ? s.cwd
            : "\(s.cwd)\n\n\(s.agent.name): \(s.recap)"
    }

    /// Small resting mark used as the item icon in the Open submenu. Every mark is
    /// tight-trimmed to its glyph, normalized to one cap height, then centered on
    /// one shared canvas (sized by the widest glyph) — identical image bounds give
    /// every row the same gutter and title inset, with no per-glyph jitter. Codex
    /// and Copilot use their clean dot-free glyph (the bar sprite carries a
    /// dot-matrix); Cursor and Gemini knock out their full-res app icon so both
    /// read at the same solid weight as the mascots.
    private static let markCapHeight: CGFloat = 13

    private static let knownGlyphs: [(id: String, glyph: NSImage)] = Agent.all.map { agent in
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
        return (agent.id, capped(template))
    }

    /// The one column every mark is centred in, known agents and generic ones
    /// alike, so a row for an agent AgentBar has never heard of lines its name up
    /// with everybody else's instead of starting a few points to the left.
    private static let markBoxWidth: CGFloat =
        knownGlyphs.map { $0.glyph.size.width }.max() ?? markCapHeight

    private static let menuMarks: [String: NSImage] =
        Dictionary(uniqueKeysWithValues: knownGlyphs.map { ($0.id, boxed($0.glyph)) })

    static func menuMark(for agent: Agent) -> NSImage {
        menuMarks[agent.id] ?? boxed(capped(trimmedTemplate(for: agent)))
    }

    /// Scaled to the shared cap height, width following the mark's own aspect.
    private static func capped(_ template: NSImage) -> NSImage {
        let img = template.copy() as! NSImage
        let scale = markCapHeight / max(img.size.height, 1)
        img.size = NSSize(width: (img.size.width * scale).rounded(), height: markCapHeight)
        return img
    }

    /// Centred in the shared box. A mark wider than the box is shrunk to fit it
    /// rather than spilling into the row's title.
    private static func boxed(_ glyph: NSImage) -> NSImage {
        let box = markBoxWidth
        let w = min(glyph.size.width, box)
        let h = glyph.size.width > box ? markCapHeight * box / glyph.size.width : markCapHeight
        let out = NSImage(size: NSSize(width: box, height: markCapHeight))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        glyph.draw(in: NSRect(x: ((box - w) / 2).rounded(), y: ((markCapHeight - h) / 2).rounded(),
                              width: w, height: h))
        out.unlockFocus()
        out.isTemplate = true
        return out
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
    private static func addInlineQuestion(to menu: NSMenu, for s: Session,
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

    /// What a strip's tag identifies. The file name alone is NOT enough: names
    /// repeat across the tools of one turn (`RequestStore` keys its snapshots the
    /// same way), and a strip left keyed to the old request would answer the new
    /// one while showing the old command — `updateInPlace` must see a replaced
    /// request as a row it isn't displaying, so the menu rebuilds.
    private static func requestKey(_ r: ApprovalRequest) -> String {
        "\(r.fileName)|\(r.identity)"
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
              Set(requests.map(requestKey)).isSubset(of: displayedRequests) else { return false }

        let live = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let liveRequests = Set(requests.map(requestKey))
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
                    let row = item.view as? SessionRowView
                    row?.update(updated)
                    row?.toolTip = rowToolTip(updated)
                    if let row { item.title = SessionRowView.plainTitle(row.content) }
                    // Keystroke fallback appears/disappears with the permission state.
                    let hasStrip = requests.contains { $0.sessionId == updated.id }
                    item.submenu = (updated.state == .permission && !hasStrip)
                        ? keystrokeSubmenu(for: updated, controller: controller) : nil
                } else {
                    (item.view as? SessionRowView)?.showEnded(s)
                    item.submenu = nil
                }
            } else if item.identifier?.rawValue == "updateRow" {
                configureUpdateRow(item, controller: controller)
            } else if item.identifier?.rawValue == "shortcutRow" {
                configureShortcutRow(item, controller: controller)
            } else if item.identifier?.rawValue == "soundsRow" {
                configureSoundsRow(item)
            } else if item.identifier?.rawValue == "diagnosticsRow" {
                configureDiagnosticsRow(item)
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

    /// Claude-look button strip for agents whose approval lives in their own UI
    /// (Antigravity dialog, Codex/Copilot terminal prompt): Allow submits the
    /// preselected option via keystroke; the second button jumps to the prompt.
    private static func addKeystrokeApproval(to menu: NSMenu, for s: Session,
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

    private static func keystrokeSubmenu(for s: Session, controller: StatusItemController) -> NSMenu {
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

/// Payload describing one approval decision (request + behavior + owning session).
final class ApprovalAction: NSObject {
    let request: ApprovalRequest
    let behavior: String   // "allow" | "always" | "deny" | "defer"
    let session: Session
    /// What to do instead, typed next to Deny. Ignored on every other verb.
    let note: String?
    init(request: ApprovalRequest, behavior: String, session: Session, note: String? = nil) {
        self.request = request
        self.behavior = behavior
        self.session = session
        self.note = note
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
