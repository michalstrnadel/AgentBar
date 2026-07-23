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
                if s.state == .permission {
                    item.submenu = approvalSubmenu(
                        for: s, requests: requests.filter { $0.sessionId == s.id },
                        controller: controller)
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
        let version = NSMenuItem(title: "Version \(appVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
        case .permission:      dotColor = NSColor(srgbRed: 0.95, green: 0.73, blue: 0.18, alpha: 1)
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

    /// Small resting mark used as the item icon in the Open submenu.
    private static func menuMark(for agent: Agent) -> NSImage {
        let sprite = IconRenderer.shared.sprite(for: agent)
        let img = sprite.restingTemplate.copy() as! NSImage
        img.size = NSSize(width: 14 * img.size.width / max(img.size.height, 1), height: 14)
        return img
    }

    /// Submenu for a session waiting on a permission prompt. Claude sessions get real
    /// Allow/Deny (the hook is blocked waiting for our answer file); agents without
    /// request files get the best-effort keystroke path.
    private static func approvalSubmenu(for s: Session, requests: [ApprovalRequest],
                                        controller: StatusItemController) -> NSMenu {
        let menu = NSMenu()
        if requests.isEmpty {
            return keystrokeSubmenu(for: s, controller: controller)
        }
        for (i, r) in requests.enumerated() {
            if i > 0 { menu.addItem(.separator()) }

            let what = NSMenuItem(title: r.display, action: nil, keyEquivalent: "")
            what.isEnabled = false
            what.toolTip = r.toolInputPretty
            menu.addItem(what)

            menu.addItem(actionItem("✓ Allow once", ApprovalAction(request: r, behavior: "allow", session: s),
                                    controller: controller))
            if let rule = r.ruleDescription {
                menu.addItem(actionItem("✓ Always allow \u{201C}\(rule)\u{201D}",
                                        ApprovalAction(request: r, behavior: "always", session: s),
                                        controller: controller))
            }
            menu.addItem(actionItem("✕ Deny", ApprovalAction(request: r, behavior: "deny", session: s),
                                    controller: controller))
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Answer in terminal instead",
                                ApprovalAction(request: requests[0], behavior: "defer", session: s),
                                controller: controller))
        return menu
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

    private static func actionItem(_ title: String, _ payload: ApprovalAction,
                                   controller: StatusItemController) -> NSMenuItem {
        let item = NSMenuItem(title: title,
                              action: #selector(StatusItemController.approvalActionClicked(_:)),
                              keyEquivalent: "")
        item.target = controller
        item.representedObject = payload
        return item
    }
}

/// Payload carried by approval menu items (NSMenuItem.representedObject needs a class).
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
