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
        menu.addItem(yourDayRow())
        menu.addItem(.separator())

        // Start a task, rather than an agent: the launcher, reachable without the
        // global chord — a keystroke nobody has heard of is a feature nobody has.
        let newTask = NSMenuItem(title: "New Task…",
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

        // Opt-in global Allow/Deny shortcut; the row opens Settings (enable + rebind).
        // Menu bar only: it is the chord that answers from anywhere, and the island
        // shows its keys on the approval card itself, where they apply.
        let shortcut = NSMenuItem(title: "Global Allow / Deny Shortcut…",
                                  action: #selector(StatusItemController.openShortcutSettings(_:)),
                                  keyEquivalent: "")
        shortcut.identifier = NSUserInterfaceItemIdentifier("shortcutRow")
        shortcut.target = controller
        shortcut.image = NSImage(systemSymbolName: "command", accessibilityDescription: nil)
        configureShortcutRow(shortcut, controller: controller)
        menu.addItem(shortcut)

        // Colour, sounds, appearance, diagnostics, Settings, updates, feedback, Quit:
        // the island's ⋯ menu renders this same list. See `AppMenuModel`.
        for item in appSection(.current, controller: controller) { menu.addItem(item) }
    }

    /// The selector every shared row is wired to on this surface.
    static let appMenuAction = #selector(StatusItemController.appMenuClicked(_:))

    /// The shared app section as this surface renders it. Its own function so a
    /// test can hold it against the island's (`AppMenuModelTests`).
    static func appSection(_ inputs: AppMenuModel.Inputs,
                           controller: StatusItemController?) -> [NSMenuItem] {
        AppMenuRenderer.items(AppMenuModel.appSection(inputs), target: controller,
                              action: appMenuAction, submenuDelegate: controller)
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
    /// The recap, one click from the Today row on both surfaces. Its own target, so
    /// neither the status item nor the island needs a selector for it.
    static func yourDayRow() -> NSMenuItem {
        let item = NSMenuItem(title: "Your Day…", action: #selector(WrapWindow.openFromMenu(_:)),
                              keyEquivalent: "")
        item.target = WrapWindow.shared
        item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        item.toolTip = "Your day with your agents, on one card to keep or share"
        return item
    }

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
    static func rowToolTip(_ s: Session) -> String {
        s.recap.isEmpty ? s.cwd
            : "\(s.cwd)\n\n\(s.agent.name): \(s.recap)"
    }


    static func configureShortcutRow(_ item: NSMenuItem, controller: StatusItemController) {
        item.state = controller.approvalShortcutEnabled ? .on : .off
        item.toolTip = controller.approvalShortcutEnabled
            ? "\(KeyCombo.allow.display) allow · \(KeyCombo.deny.display) deny the newest pending request — click to configure"
            : "Off — click to enable and pick the keys"
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
