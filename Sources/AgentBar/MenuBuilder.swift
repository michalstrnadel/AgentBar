import Cocoa

/// Builds the dropdown menu from a session snapshot. Stateless: every open rebuilds.
enum MenuBuilder {
    static func populate(_ menu: NSMenu, sessions: [Session], controller: StatusItemController) {
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
}
