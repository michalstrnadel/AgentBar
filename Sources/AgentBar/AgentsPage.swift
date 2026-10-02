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
