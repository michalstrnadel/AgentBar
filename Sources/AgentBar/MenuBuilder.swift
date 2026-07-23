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
                item.toolTip = s.cwd
                let sessionRequests = requests.filter { $0.sessionId == s.id }
                if s.state == .permission {
                    if !sessionRequests.isEmpty {
                        // Row click defers to the session's own UI; actions live right below.
                        menu.addItem(item)
                        addInlineApproval(to: menu, for: s, requests: sessionRequests,
                                          controller: controller)
                        continue
                    }
                    // No request file (non-Claude agent): best-effort keystroke path.
                    item.submenu = keystrokeSubmenu(for: s, controller: controller)
                }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        // Open
        let openParent = NSMenuItem(title: "Open", action: nil, keyEquivalent: "")
        let openSub = NSMenu()
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
        let colorSub = NSMenu()
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
        if !badge.isEmpty {
            if #available(macOS 14.0, *) {
                item.badge = NSMenuItemBadge(string: badge)
            } else {
                item.toolTip = "AgentBar \(badge)"
            }
        }
        return item
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
        let sub = s.state == .permission ? "  needs approval" : (s.label.isEmpty ? "" : "  \(s.label)")
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

    /// Small resting mark used as the item icon in the Open submenu. Uses the clean
    /// dot-free glyph for the agents whose bar sprite carries a dot-matrix (codex,
    /// copilot); others fall back to their sprite's resting frame (already clean).
    private static func menuMark(for agent: Agent) -> NSImage {
        let template: NSImage
        switch agent.id {
        case "codex":
            template = IconRenderer.decode(codexMascotMarkPNG).map {
                IconRenderer.solidTemplate(IconRenderer.trim($0))
            } ?? IconRenderer.shared.sprite(for: agent).restingTemplate
        case "copilot":
            template = IconRenderer.decode(copilotMascotMarkPNG).map {
                IconRenderer.adaptiveTemplate(IconRenderer.trim($0))
            } ?? IconRenderer.shared.sprite(for: agent).restingTemplate
        default:
            template = IconRenderer.shared.sprite(for: agent).restingTemplate
        }
        let img = template.copy() as! NSImage
        img.size = NSSize(width: 14 * img.size.width / max(img.size.height, 1), height: 14)
        return img
    }

    /// The pending command and an Allow/Always/Deny/defer button strip inserted
    /// directly under the session row — no second navigation level.
    private static func addInlineApproval(to menu: NSMenu, for s: Session,
                                          requests: [ApprovalRequest],
                                          controller: StatusItemController) {
        for r in requests {
            let what = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            what.isEnabled = false
            what.toolTip = r.toolInputPretty
            what.attributedTitle = NSAttributedString(string: "      \(r.display)", attributes: [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            menu.addItem(what)

            let buttons = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            buttons.view = ApprovalButtonsRow(
                hasRule: r.ruleDescription != nil,
                ruleToolTip: r.ruleDescription.map { "Always allow \($0)" },
                deferTitle: s.entrypoint == "claude-desktop" ? "⧉ Claude app" : "⌨ Terminal",
                onChoose: { [weak controller] behavior in
                    controller?.answer(ApprovalAction(request: r, behavior: behavior, session: s))
                })
            menu.addItem(buttons)
        }
    }

    private static func keystrokeSubmenu(for s: Session, controller: StatusItemController) -> NSMenu {
        let menu = NSMenu()
        let agent = Agent.byID(s.agentID)
        let note = NSMenuItem(title: "Can't show the request for \(agent.name)",
                              action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
        if agent.approveKeys != nil {
            let title = KeystrokeApprover.trusted
                ? "Approve in terminal (sends keystroke)" : "Grant Accessibility…"
            let item = NSMenuItem(title: title,
                                  action: #selector(StatusItemController.keystrokeApproveClicked(_:)),
                                  keyEquivalent: "")
            item.target = controller
            item.representedObject = s
            menu.addItem(item)
        }
        let open = NSMenuItem(title: "Open in terminal",
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
