import Foundation

/// What Settings ▸ Agents says, worked out from history and the wiring switches
/// without a window — so every sentence on the page can be tested. `SettingsWindow`
/// builds the rows; this decides their words.
///
/// The page answers the two questions someone has about an agent: is AgentBar wired
/// into it, and is it actually reporting. The second is what the switch alone
/// cannot say — a wired agent that never shows up is the shape of a broken
/// integration, and "last session today" beside the switch settles it at a glance.
enum AgentsPage {
    /// The line beside an integration's switch.
    static func state(present: Bool, off: Bool, lastSession: TimeInterval?,
                      now: TimeInterval) -> String {
        guard present else { return "Not on this Mac" }
        if off { return "Off — your choice" }
        guard let last = lastSession, last > 0 else { return "Wired · no session yet" }
        return "Wired · " + ago(last, now: now)
    }

    /// "today", "yesterday", "3 days ago" — in calendar days, because "last session
    /// 1 day ago" for something that happened at 23:50 yesterday reads as a lie.
    static func ago(_ t: TimeInterval, now: TimeInterval, calendar: Calendar = .current) -> String {
        let then = calendar.startOfDay(for: Date(timeIntervalSince1970: t))
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: now))
        let days = max(0, calendar.dateComponents([.day], from: then, to: today).day ?? 0)
        switch days {
        case 0: return "last session today"
        case 1: return "last session yesterday"
        default: return "last session \(days) days ago"
        }
    }

    /// The newest end per agent id, for every agent in `records`.
    static func lastSessions(_ records: [HistoryStore.Record]) -> [String: TimeInterval] {
        var out: [String: TimeInterval] = [:]
        for r in records where r.endedAt > out[r.agent] ?? 0 { out[r.agent] = r.endedAt }
        return out
    }

    /// Agents that reported through `agentbar report` (or any bridge) rather than a
    /// hook AgentBar installed, newest first, each by the name it gave itself. They
    /// have no switch — nothing was wired into them — so this list is the only
    /// place the page can show that they are there.
    static func ownAgents(_ records: [HistoryStore.Record], limit: Int = 6) -> [String] {
        let known = Set(Agent.all.map(\.id))
        var newest: [String: (name: String, at: TimeInterval)] = [:]
        for r in records where !known.contains(r.agent) && !r.agent.isEmpty {
            if r.endedAt >= newest[r.agent]?.at ?? -1 {
                newest[r.agent] = (r.resolvedAgent.name, r.endedAt)
            }
        }
        return newest.values.sorted { $0.at > $1.at }.prefix(limit).map(\.name)
    }

    /// The line under "Your own agent".
    static func ownAgentsNote(_ names: [String]) -> String {
        guard !names.isEmpty else {
            return "None yet. Anything that can run a command can appear here — "
                + "it shows up under its own name, with nothing to switch on."
        }
        return "Seen this month: " + names.joined(separator: ", ") + "."
    }

    // MARK: - The Claude Code mod

    /// The line under the mod's switch. It starts off, so the off line is the one
    /// most people read, and it says what switching on buys rather than only that
    /// it is off.
    static func modState(present: Bool, supported: Bool, off: Bool,
                         lastReport: TimeInterval?, now: TimeInterval) -> String {
        guard present else { return "Not on this Mac" }
        guard supported else { return "Needs Claude Code \(ClaudeModWiring.minimumVersion) or later" }
        if off { return "Off — turn on to see what Claude Code runs without asking you, and its live quota" }
        guard let last = lastReport, last > 0 else { return "On · no report yet — it starts with the next Claude Code session" }
        return "On · " + ago(last, now: now).replacingOccurrences(of: "last session", with: "reported")
    }

    // MARK: - Plugins that can answer for you

    static let pluginsTitle = "Claude Code plugins that can answer for you"
    static let pluginsLoading = "Reading your Claude Code plugins…"
    static let pluginsEmpty = "No plugin can answer Claude Code's prompts for you."
    /// Under the card: why the card exists at all.
    static let pluginsFootnote = "A plugin that answers settles the prompt inside Claude Code: it never "
        + "reaches AgentBar, and no rule of yours was asked. With the Claude Code mod on, what "
        + "one decides before a prompt is due lands in your record, marked as a hook's; a hook "
        + "that answers the prompt itself does not."

    /// The line under a plugin's name: what it can do, and where it is enabled when
    /// more than one Claude config dir is in play.
    static func pluginDetail(_ p: PluginInventory.Plugin, showDirs: Bool,
                             home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        var s = p.sentence.prefix(1).uppercased() + p.sentence.dropFirst()
        if showDirs, !p.configDirs.isEmpty {
            s += " · in " + p.configDirs.map { tilde($0.path, home: home) }.joined(separator: ", ")
        }
        return s + "."
    }

    /// The small tag beside a plugin: what kind of thing it is, and whether its
    /// hooks were read by Claude Code or guessed from the source.
    static func pluginBadge(_ p: PluginInventory.Plugin) -> String {
        switch p.kind {
        case .mod: return p.estimated ? "Mod · from source" : "Mod"
        case .hooks: return "Hook"
        case .other: return "Plugin"
        }
    }

    /// Whether to name config dirs: only when the answering plugins span more than one.
    static func showsDirs(_ plugins: [PluginInventory.Plugin]) -> Bool {
        Set(plugins.flatMap { $0.configDirs.map(\.path) }).count > 1
    }

    /// The dim line after the answering ones: everything else that is loaded, each
    /// with a word on what it does when there is one. nil when there is nothing.
    static func alsoLoaded(_ plugins: [PluginInventory.Plugin], limit: Int = 8) -> String? {
        let rest = plugins.filter { !$0.canAnswer }
        guard !rest.isEmpty else { return nil }
        let named = rest.prefix(limit).map { p -> String in
            let note = p.ours ? "observes only" : PluginInventory.note(kind: p.kind, events: p.events)
            return note.map { "\(p.name) (\($0))" } ?? p.name
        }
        let more = rest.count > limit ? ", and \(rest.count - limit) more" : ""
        return "Also loaded: " + named.joined(separator: ", ") + more + "."
    }

    static func tilde(_ path: String, home: String) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// What **Copy example** puts on the clipboard: a wrapper that shows any command
    /// as a session for as long as it runs. Short enough to read before pasting.
    static let example = """
    # Show any command in AgentBar while it runs — e.g. aider, goose, a script.
    agentbar report --agent aider --name Aider --state thinking --label "Working" --pid $$
    aider "$@"; code=$?
    agentbar report --agent aider --state end
    exit $code
    """
}
