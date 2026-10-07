import Cocoa

/// Carry a session's work over to another agent — most of all when its quota is
/// about to run out and the forecast says so.
///
/// It is the launcher, filled in: the same project, another agent, and a prompt
/// that says what the first one was doing. Nothing more. The prompt is on screen
/// in the launcher before anything runs, Return is still the person's, and the new
/// session starts beside the old one rather than replacing it — the old one is
/// not stopped, told anything, or touched.
///
/// The prompt quotes two things: the person's own last prompt, and the agent's
/// last recap. The recap is the agent's words, so it goes in quoted, cut to one
/// short line, and only into a field the person reads before pressing Return.
enum Handoff {
    /// The quota a session draws on, as `UsageCenter` names its provider.
    static func provider(for agentID: String) -> String? {
        switch agentID {
        case "claude": return "Claude"
        case "codex":  return "Codex"
        case "copilot": return "Copilot"
        default:       return nil
        }
    }

    /// When this session's quota runs out at the current pace, if that is within
    /// half an hour — the moment to think about carrying on elsewhere. Nil for a
    /// session that is not working, or whose provider says nothing that soon.
    static func runningOut(_ s: Session, readings: [UsageCenter.Reading],
                           forecast: (String, UsageWindow) -> UsagePace.Forecast? = {
                               UsagePace.shared.forecast(provider: $0, window: $1) },
                           now: Date = Date()) -> UsagePace.Forecast? {
        guard s.state.isWorking || s.state == .done, !s.decayed, s.entrypoint != "cloud",
              let p = provider(for: s.agentID),
              let r = readings.first(where: { $0.provider == p }) else { return nil }
        return r.windows
            .filter { !$0.expired(now: now) }
            .compactMap { forecast(p, $0) }
            .filter { UsagePace.urgent($0, now: now) }
            .min { $0.runsOutAt < $1.runsOutAt }
    }

    /// The agents it can go to: every one this Mac can start, except the one it is
    /// leaving — those that take a prompt first, because the point is the prompt.
    static func targets(from s: Session, launchable: [Agent] = Launcher.launchableAgents()) -> [Agent] {
        let others = launchable.filter { $0.id != s.agentID }
        return others.filter(\.takesPrompt) + others.filter { !$0.takesPrompt }
    }

    /// One line the next agent can start from. One line because the launcher's
    /// field is one line, and what is not on screen is not read.
    static func prompt(for s: Session) -> String {
        let task = clip(s.prompt, 160)
        let recap = clip(s.recap, 140)
        var out = "Pick up where \(s.agent.name) left off in \(s.project.isEmpty ? "this project" : s.project)."
        out += task.isEmpty ? " I'll tell you what the task was if it isn't clear."
                            : " The task: “\(task)”."
        if !recap.isEmpty { out += " Its last update: “\(recap)”." }
        out += " Look at `git status` and `git diff` first to see what has already changed, then carry on."
        return out
    }

    /// One line, at most `max` characters, cut at a word.
    static func clip(_ s: String, _ max: Int) -> String {
        let one = s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        guard one.count > max else { return one }
        let cut = String(one.prefix(max - 1))
        let word = cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? cut
        return (word.count > max / 2 ? word : cut) + "…"
    }

    /// What the launcher is filled with.
    static func fill(_ s: Session, to agent: Agent) -> URLCommands.Prefill {
        URLCommands.Prefill(cwd: s.cwd, agent: agent.id, prompt: prompt(for: s))
    }

    /// Whether a session can be carried over at all: it has a folder on this Mac.
    static func canHandOff(_ s: Session) -> Bool {
        s.entrypoint != "cloud" && !s.cwd.isEmpty && FileManager.default.fileExists(atPath: s.cwd)
    }
}

/// The menu both surfaces show: Continue in ▸ each agent, and the prompt to copy.
final class HandoffMenu: NSObject {
    static let shared = HandoffMenu()

    /// Items for `s`, or none when it cannot be carried anywhere.
    func items(for s: Session, runningOut: UsagePace.Forecast? = nil) -> [NSMenuItem] {
        guard Handoff.canHandOff(s) else { return [] }
        let targets = Handoff.targets(from: s)
        guard !targets.isEmpty else { return [] }
        var out: [NSMenuItem] = []
        let title: String
        if let f = runningOut {
            title = "\(s.agent.name) runs out ~\(UsageCenter.when(f.runsOutAt, now: Date())) — continue in"
        } else {
            title = "Continue in"
        }
        // A header, not a row: disabled and plain, as macOS 14's section header
        // would draw it, on the macOS 12 this still supports.
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        out.append(header)
        for agent in targets {
            let item = NSMenuItem(title: agent.name + "…", action: #selector(continueIn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Pick(session: s, agent: agent)
            item.image = MenuBuilder.menuMark(for: agent)
            item.toolTip = agent.takesPrompt
                ? "Opens the launcher in \(s.project) with \(agent.name) and a prompt that says where \(s.agent.name) got to. Return starts it."
                : "\(agent.name) takes no prompt on the command line: the launcher opens it in \(s.project), and the prompt is on the clipboard."
            out.append(item)
        }
        let copy = NSMenuItem(title: "Copy Handoff Prompt", action: #selector(copyPrompt(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = Pick(session: s, agent: nil)
        out.append(copy)
        return out
    }

    func menu(for s: Session, runningOut: UsagePace.Forecast? = nil) -> NSMenu? {
        let items = items(for: s, runningOut: runningOut)
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        items.forEach(menu.addItem)
        return menu
    }

    private final class Pick: NSObject {
        let session: Session
        let agent: Agent?
        init(session: Session, agent: Agent?) { self.session = session; self.agent = agent }
    }

    @objc private func continueIn(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick, let agent = pick.agent else { return }
        if !agent.takesPrompt { put(Handoff.prompt(for: pick.session)) }
        LauncherPanel.shared.show(prefill: Handoff.fill(pick.session, to: agent),
                                  handedFrom: pick.session.agent.name)
    }

    @objc private func copyPrompt(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick else { return }
        put(Handoff.prompt(for: pick.session))
    }

    private func put(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
