import Foundation
import Testing
@testable import AgentBar

/// The words on Settings ▸ Agents. The switch says what AgentBar did; the line
/// beside it says whether that worked, and that is the part worth pinning down.
@Suite struct AgentsPageTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func record(_ agent: String, name: String = "", ended: TimeInterval) -> HistoryStore.Record {
        var o: [String: Any] = ["agent": agent, "sessionId": "s-\(agent)-\(Int(ended))",
                                "startedAt": Int(ended) - 60, "endedAt": Int(ended), "state": "done"]
        if !name.isEmpty { o["agentName"] = name }
        let line = String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
        return HistoryStore.Record(jsonLine: line)!
    }

    /// The mod starts off, so its off line is the one most people read: it says
    /// what switching on buys, not merely that it is off.
    @Test func theModsLineSaysWhatTurningItOnBuys() {
        let now: TimeInterval = 1_790_000_000
        func s(present: Bool = true, supported: Bool = true, off: Bool = false, last: TimeInterval? = nil) -> String {
            AgentsPage.modState(present: present, supported: supported, off: off, lastReport: last, now: now)
        }
        #expect(s(present: false) == "Not on this Mac")
        #expect(s(supported: false, off: true) == "Needs Claude Code 2.1.287 or later")
        #expect(s(off: true) == "Off — turn on to see what Claude Code runs without asking you, and its live quota")
        #expect(s(last: now - 30).hasPrefix("On · reported today"))
        #expect(s().hasPrefix("On · no report yet"))
    }

    @Test func thePluginsCardSpeaksForEveryState() {
        #expect(AgentsPage.pluginsEmpty == "No plugin can answer Claude Code's prompts for you.")
        #expect(AgentsPage.alsoLoaded([]) == nil)
        let weather = PluginInventory.Plugin(key: "token-weather@m", name: "token-weather",
                                             configDirs: [URL(fileURLWithPath: "/h/.claude-work")],
                                             installPath: "/p/tw", kind: .mod,
                                             events: [.init(name: "ui.render", filter: ["component": "AbovePrompt"])],
                                             estimated: false, ours: false)
        let figma = PluginInventory.Plugin(key: "figma@m", name: "figma", configDirs: [], installPath: "/p/f",
                                           kind: .other, events: [], estimated: false, ours: false)
        #expect(AgentsPage.alsoLoaded([weather, figma]) == "Also loaded: token-weather (draws in the terminal), figma.")
        let blast = PluginInventory.Plugin(key: "blast-radius@m", name: "blast-radius",
                                           configDirs: [URL(fileURLWithPath: "/h/.claude-work"),
                                                        URL(fileURLWithPath: "/h/.claude")],
                                           installPath: "/p/br", kind: .mod,
                                           events: [.init(name: "tool.call", filter: ["tool": "Bash"])],
                                           estimated: false, ours: false)
        #expect(AgentsPage.pluginDetail(blast, showDirs: true, home: "/h")
                == "Can hold or refuse Bash commands before they run · in ~/.claude-work, ~/.claude.")
        #expect(AgentsPage.pluginDetail(blast, showDirs: false, home: "/h")
                == "Can hold or refuse Bash commands before they run.")
        #expect(AgentsPage.pluginBadge(blast) == "Mod")
        let many = (0..<10).map { i in
            PluginInventory.Plugin(key: "p\(i)", name: "p\(i)", configDirs: [], installPath: "/p\(i)",
                                   kind: .other, events: [], estimated: false, ours: false)
        }
        #expect(AgentsPage.alsoLoaded(many)?.hasSuffix(", and 2 more.") == true)
    }

    @Test func theLineSaysWhatTheSwitchCannot() {
        let now: TimeInterval = 1_790_000_000
        #expect(AgentsPage.state(present: false, off: false, lastSession: nil, now: now) == "Not on this Mac")
        #expect(AgentsPage.state(present: true, off: true, lastSession: now, now: now) == "Off — your choice")
        #expect(AgentsPage.state(present: true, off: false, lastSession: nil, now: now) == "Wired · no session yet")
        #expect(AgentsPage.state(present: true, off: false, lastSession: now - 30, now: now)
                .hasPrefix("Wired · last session"))
    }

    /// Calendar days: 23:50 yesterday is "yesterday", not "today" and not "0 days".
    @Test func agoCountsCalendarDays() {
        let now: TimeInterval = 1_790_000_000 - 1_790_000_000.truncatingRemainder(dividingBy: 86_400) + 600
        #expect(AgentsPage.ago(now - 300, now: now, calendar: utc) == "last session today")
        #expect(AgentsPage.ago(now - 1_200, now: now, calendar: utc) == "last session yesterday")
        #expect(AgentsPage.ago(now - 3 * 86_400, now: now, calendar: utc) == "last session 3 days ago")
        #expect(AgentsPage.ago(now + 500, now: now, calendar: utc) == "last session today")
    }

    @Test func theNewestSessionWins() {
        let last = AgentsPage.lastSessions([record("claude", ended: 10), record("claude", ended: 30),
                                            record("codex", ended: 20)])
        #expect(last == ["claude": 30, "codex": 20])
    }

    /// Only agents with no integration of their own, newest first, by the name each
    /// gave itself — a known agent is already on the card with its switch.
    @Test func ownAgentsAreTheOnesNobodyWired() {
        let names = AgentsPage.ownAgents([record("claude", ended: 50),
                                          record("aider", name: "Aider", ended: 10),
                                          record("goose", name: "Goose", ended: 40),
                                          record("aider", name: "Aider", ended: 30)])
        #expect(names == ["Goose", "Aider"])
        #expect(AgentsPage.ownAgentsNote(names) == "Seen this month: Goose, Aider.")
        #expect(AgentsPage.ownAgentsNote([]).hasPrefix("None yet."))
    }

    /// The example is pasted into a shell; it must use only what `report` accepts.
    @Test func theExampleUsesTheRealFlags() {
        #expect(AgentsPage.example.contains("agentbar report --agent aider"))
        #expect(AgentsPage.example.contains("--state end"))
        #expect(!AgentsPage.example.contains("--state permission"))
    }
}
