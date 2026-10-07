import Cocoa

/// The launcher: a repo, an agent, a line of what you want, and return.
///
/// A third surface, and the only one the user summons rather than the app showing.
/// It takes no space until a keystroke asks for it, it closes the moment it loses
/// focus, and it never appears on its own — the conditions rule 2 sets for
/// anything beyond the menu bar item and the island.
///
/// Off until switched on, like every other global key this app registers: a chord
/// claimed system-wide by an app you did not ask to claim it is a chord stolen from
/// whatever you were already using it for.
final class LauncherPanel: NSObject, NSWindowDelegate {
    static let shared = LauncherPanel()

    static var shortcutEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "launcherShortcut") }
        set { UserDefaults.standard.set(newValue, forKey: "launcherShortcut") }
    }

    /// Fed by the app delegate, so the panel reads one poll like every other
    /// surface instead of going to disk itself.
    static var sessions: () -> [Session] = { [] }

    private var panel: NSPanel?
    private var field: NSTextField!
    private var projectRow: NSStackView!
    private var agentRow: NSStackView!
    private var hint: NSTextField!
    private var projects: [(project: String, cwd: String)] = []
    private var agents: [Agent] = []
    private var chosenProject = 0
    private var chosenAgent = 0
    /// True while what is in the panel came from an `agentbar://new-task` link
    /// rather than from the person. The hint says so for as long as the panel is
    /// open: choosing another project does not make the prompt theirs.
    private var fromLink = false
    /// False while a link-filled panel has not been confirmed. The field is focused
    /// either way; what changes is what the first Return does. A page that opened
    /// the link can also tell you to "press Enter to continue", so for a link the
    /// first Return only arms the panel — and only once it has been on screen long
    /// enough to be read. Editing the prompt arms it too: then it is your prompt.
    private var armed = true
    /// The agent a handoff came from (`Handoff`): the prompt was written by
    /// AgentBar from that session, so the hint says so — but it came from a click
    /// the person made, so one Return starts it, as for anything they chose.
    private var handedFrom: String?
    private var shownAt = Date.distantPast

    // MARK: - Showing

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() { show(prefill: nil) }

    /// The launcher, already filled in — what `agentbar://new-task` opens.
    ///
    /// Filled in and nothing more: the panel still waits for Return, exactly as if
    /// the person had typed it all, because the link that filled it may have come
    /// from any web page (see `URLCommands`). The parser has already refused a
    /// `cwd` that is not an absolute, existing directory; here a directory that is
    /// not among the recent projects joins them at the front, so what will run is
    /// on screen and selected rather than implied. An agent id this machine cannot
    /// start is dropped and the usual first agent stays chosen — a link naming
    /// something that is not installed is not a reason to show nothing.
    func show(prefill: URLCommands.Prefill?, handedFrom: String? = nil) {
        projects = Launcher.recentProjects(sessions: Self.sessions(),
                                           history: HistoryStore.cached())
        agents = Launcher.launchableAgents()
        guard !agents.isEmpty else {
            // Nothing on this machine could be started. Saying so beats a panel
            // whose buttons all do nothing — and beats a beep, which says only no.
            Self.note("No agent to start",
                      "AgentBar found no supported agent's command line on this Mac. It looks in "
                      + "~/.local/bin, /opt/homebrew/bin, /usr/local/bin and your PATH. Install "
                      + "Claude Code, Codex, Gemini CLI or another supported agent, then try again.")
            return
        }
        chosenProject = 0
        chosenAgent = 0
        if let cwd = prefill?.cwd {
            if let i = projects.firstIndex(where: { $0.cwd == cwd }) {
                chosenProject = i
            } else {
                projects.insert(((cwd as NSString).lastPathComponent, cwd), at: 0)
                if projects.count > 6 { projects.removeLast() }
            }
        }
        if let id = prefill?.agent, let i = agents.firstIndex(where: { $0.id == id }) {
            chosenAgent = i
        }
        // A link arriving while the panel is open with something typed in it must
        // not replace what the person wrote.
        let keepTyped = panel?.isVisible == true && !(field?.stringValue.isEmpty ?? true)
        // A plain show over a panel that kept its text keeps what that text is: a
        // link-filled prompt opened again from the menu or the hotkey is still one
        // the person did not write, and still owes its second Return.
        if prefill != nil || !keepTyped {
            fromLink = prefill != nil && handedFrom == nil
            armed = !fromLink
            self.handedFrom = keepTyped ? nil : handedFrom
        }
        shownAt = Date()
        if panel == nil { build() }
        rebuildRows()
        if !keepTyped { field.stringValue = prefill?.prompt ?? "" }
        syncHint()
        centreOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(field)
    }

    func close() { panel?.orderOut(nil) }

    /// Closing on blur is what makes it a launcher rather than a window: it is
    /// either the thing you are doing or it is gone.
    func windowDidResignKey(_ notification: Notification) { close() }

    private func centreOnActiveScreen() {
        guard let panel, let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        // A third of the way down, where a launcher belongs: high enough to read
        // without covering what you were looking at.
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - visible.height / 3 - size.height / 2))
    }

    // MARK: - Building

    private func build() {
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 150),
                         styleMask: [.titled, .fullSizeContentView],
                         backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.level = .floating
        p.delegate = self
        p.isReleasedWhenClosed = false

        field = NSTextField()
        field.placeholderString = "What should it do?"
        field.font = .systemFont(ofSize: 15)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.target = self
        field.action = #selector(startFromField)
        field.delegate = self

        projectRow = row()
        agentRow = row()
        hint = NSTextField(labelWithString: "")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [field, projectRow, agentRow, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
        ])
        p.contentView = content
        panel = p
    }

    private func row() -> NSStackView {
        let r = NSStackView()
        r.orientation = .horizontal
        r.spacing = 6
        return r
    }

    private func rebuildRows() {
        projectRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        agentRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, project) in projects.enumerated() {
            let b = pill(project.project, tag: i, action: #selector(chooseProject(_:)))
            b.toolTip = project.cwd
            projectRow.addArrangedSubview(b)
        }
        if projects.isEmpty {
            let none = NSTextField(labelWithString: "No project yet — run any agent in a folder once")
            none.font = .systemFont(ofSize: 11)
            none.textColor = .tertiaryLabelColor
            projectRow.addArrangedSubview(none)
        }
        for (i, agent) in agents.enumerated() {
            agentRow.addArrangedSubview(pill(agent.name, tag: i, action: #selector(chooseAgent(_:))))
        }
        syncSelection()
        panel?.setContentSize(NSSize(width: 460,
                                     height: panel?.contentView?.fittingSize.height ?? 150))
    }

    private func pill(_ title: String, tag: Int, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.tag = tag
        b.bezelStyle = .recessed
        b.setButtonType(.pushOnPushOff)
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        // Six long project names in one row overflowed the panel; the middle of a
        // name is the part least needed to tell it apart, and the tooltip has it all.
        b.cell?.lineBreakMode = .byTruncatingMiddle
        b.widthAnchor.constraint(lessThanOrEqualToConstant: 110).isActive = true
        return b
    }

    private func syncSelection() {
        for (i, v) in projectRow.arrangedSubviews.enumerated() {
            (v as? NSButton)?.state = i == chosenProject ? .on : .off
        }
        for (i, v) in agentRow.arrangedSubviews.enumerated() {
            (v as? NSButton)?.state = i == chosenAgent ? .on : .off
        }
        syncHint()
    }

    /// Says what return will do, including when it will not do all of it. An agent
    /// that cannot be handed a prompt says so here rather than swallowing what you
    /// typed.
    private func syncHint() {
        guard let agent = agents.indices.contains(chosenAgent) ? agents[chosenAgent] : nil,
              let project = projects.indices.contains(chosenProject) ? projects[chosenProject] : nil
        else {
            hint.stringValue = projects.isEmpty
                ? "Nothing to start in yet · esc closes"
                : "⏎ start · esc closes"
            return
        }
        var text = "⏎ opens \(agent.name) in \(project.project)"
        if !agent.takesPrompt {
            text += " — it takes no prompt on the command line, so type it there"
        }
        // Said before anything else, because it is the thing to check first: a
        // prompt the person did not type is one they have to read.
        if fromLink {
            text = armed ? "From a link · " + text
                         : "From a link — read it, then ⏎ twice · " + text
        } else if let from = handedFrom {
            text = "Carrying on from \(from) — read it first · " + text
        }
        // The keys, once there is more than one thing to choose between.
        let keys = [projects.count > 1 ? "↑↓ project" : nil, agents.count > 1 ? "⇥ agent" : nil]
            .compactMap { $0 }
        hint.stringValue = text + (keys.isEmpty ? "" : " · " + keys.joined(separator: " · ")) + " · esc closes"
    }

    // MARK: - Acting

    @objc private func chooseProject(_ sender: NSButton) {
        chosenProject = sender.tag
        syncSelection()
        panel?.makeFirstResponder(field)
    }

    @objc private func chooseAgent(_ sender: NSButton) {
        chosenAgent = sender.tag
        syncSelection()
        panel?.makeFirstResponder(field)
    }

    @objc private func startFromField() {
        guard armed else {
            // The first Return confirms you have seen it; a second, deliberate one
            // starts it. A Return inside the first second is the one that was
            // already on its way when the panel appeared, and does nothing.
            if Date().timeIntervalSince(shownAt) > 1 { armed = true }
            syncHint()
            return
        }
        start()
    }

    func start() {
        guard agents.indices.contains(chosenAgent),
              projects.indices.contains(chosenProject) else { return }
        let task = Launcher.Task(agent: agents[chosenAgent],
                                 cwd: projects[chosenProject].cwd,
                                 prompt: field.stringValue)
        close()
        // Read here, on the main thread that writes them; the queue below gets a copy.
        let sessions = Self.sessions()
        // Off the main thread: an AppleScript that has never been allowed sits on
        // the consent dialog for as long as it takes somebody to read it.
        DispatchQueue.global(qos: .userInitiated).async {
            let terminal = TerminalApp.preferred(sessions: sessions)
            let outcome = Launcher.start(task, terminal: terminal)
            DispatchQueue.main.async { Self.report(outcome, terminal: terminal) }
        }
    }

    /// The two outcomes that are not "it started" get said out loud. A launcher
    /// that quietly does nothing is worse than no launcher.
    private static func report(_ outcome: Launcher.Outcome, terminal: TerminalApp) {
        switch outcome {
        case .started:
            return
        case .copied:
            note("\(terminal.name) can't be handed a command",
                 "The command is on your clipboard — paste it in the window that just opened.")
        case .noCLI:
            note("That agent isn't installed here",
                 "AgentBar found no command for it on this machine.")
        }
    }

    private static func note(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// A borderless-looking panel still has to take the keyboard, and a plain `NSPanel`
/// will not become key while its title bar is hidden.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Escape closes it. `cancelOperation` is what the responder chain sends for
    /// escape, and without it the key beeps at a window with nothing to cancel.
    override func cancelOperation(_ sender: Any?) {
        LauncherPanel.shared.close()
    }
}

extension LauncherPanel: NSTextFieldDelegate {
    /// The pills by keyboard: ↑ and ↓ walk the projects, ⇥ and ⇧⇥ the agents. The
    /// field keeps the focus, so typing carries on where it was.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        func step(_ i: Int, _ by: Int, _ count: Int) -> Int { count == 0 ? i : (i + by + count) % count }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):       chosenProject = step(chosenProject, -1, projects.count)
        case #selector(NSResponder.moveDown(_:)):     chosenProject = step(chosenProject, 1, projects.count)
        case #selector(NSResponder.insertTab(_:)):     chosenAgent = step(chosenAgent, 1, agents.count)
        case #selector(NSResponder.insertBacktab(_:)): chosenAgent = step(chosenAgent, -1, agents.count)
        default: return false
        }
        syncSelection()
        return true
    }

    /// Typing into a link-filled prompt makes it yours: it no longer needs the
    /// extra confirmation a prompt you did not write does.
    func controlTextDidChange(_ obj: Notification) {
        guard fromLink, !armed else { return }
        armed = true
        syncHint()
    }
}
