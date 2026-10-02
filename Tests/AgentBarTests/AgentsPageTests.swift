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
