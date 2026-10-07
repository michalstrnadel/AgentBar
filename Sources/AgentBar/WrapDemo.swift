import Foundation

/// A made-up day, for pictures of the recap: the README, the promo film, and the
/// offscreen render that checks every slide. Never shown in the app — a recap of
/// somebody else's day is exactly the invented number `DayWrap` refuses to show.
enum WrapDemo {
    static func wrap(_ range: DayWrap.Range, now: TimeInterval = Date().timeIntervalSince1970,
                     calendar: Calendar = .current) -> DayWrap {
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970
        let end = midnight + 22.5 * 3600
        func at(_ h: Double, day: Int = 0) -> TimeInterval { midnight + Double(day) * 86_400 + h * 3600 }
        var records: [HistoryStore.Record] = []
        func add(_ agent: String, _ project: String, _ from: Double, _ to: Double, day: Int = 0,
                 prompt: String = "", change: (Int, Int, Int)? = nil, state: String = "done") {
            var c = ""
            if let change { c = #","change":{"files":\#(change.0),"added":\#(change.1),"removed":\#(change.2)}"# }
            let line = #"{"agent":"\#(agent)","sessionId":"demo-\#(records.count)","project":"\#(project)","cwd":"/demo/\#(project)","prompt":"\#(prompt)","startedAt":\#(Int(at(from, day: day))),"endedAt":\#(Int(at(to, day: day))),"state":"\#(state)"\#(c)}"#
            if let r = HistoryStore.Record(jsonLine: line) { records.append(r) }
        }
        add("claude", "AgentBar", 8.2, 10.9, prompt: "Build the Your Day recap, Wrapped style", change: (14, 1_240, 310))
        add("codex", "landing-site", 9.1, 9.9, change: (6, 380, 122))
        add("copilot", "landing-site", 9.4, 10.1, change: (3, 96, 40))
        add("claude", "AgentBar", 11.5, 12.4, prompt: "Fix the island hover", change: (4, 210, 88))
        add("gemini", "ml-notebooks", 13.2, 14.6, change: (5, 140, 60))
        add("claude", "AgentBar", 14.0, 15.8, prompt: "Drop a file onto a session", change: (9, 512, 101))
        add("codex", "api", 14.3, 15.1, change: (7, 288, 190))
        add("cursor", "landing-site", 16.0, 16.7, change: (2, 64, 12))
        add("claude", "api", 20.5, 21.7, change: (5, 230, 45))
        add("claude", "AgentBar", 22.4, 23.2, prompt: "Ship 1.44", change: (3, 90, 20))
        if range == .week {
            for d in 1...6 {
                add("claude", "AgentBar", 9, 9 + Double(d % 4) + 1.2, day: -d)
                add("codex", "api", 13, 13 + Double(d % 3) * 0.7 + 0.5, day: -d)
            }
        }
        var ledger: [DecisionLedger.Record] = []
        for (i, w) in [3.0, 5, 8, 4, 12, 2, 41, 6, 9, 3, 15, 7, 4, 22, 5, 3, 6, 11].enumerated() {
            var r = DecisionLedger.Record()
            r.ts = at(8.5 + Double(i) * 0.7); r.waited = w; r.via = "app"; r.decision = "allow"; r.shape = "bash:ls"
            ledger.append(r)
        }
        for i in 0..<7 {
            var r = DecisionLedger.Record()
            r.ts = at(9 + Double(i)); r.via = "rule"; r.decision = "allow"; r.shape = "bash:git status"
            ledger.append(r)
        }
        return DayWrap.make(range, history: records, ledger: ledger,
                            now: range == .today ? end : end, calendar: calendar)
    }
}
