import Foundation

/// A made-up day, for pictures of the recap: the README, the promo film, and the
/// offscreen render that checks the card. Never shown in the app — a recap of
/// somebody else's day is exactly the invented number `DayWrap` refuses to show.
enum WrapDemo {
    static func wrap(_ range: DayWrap.Range, now: TimeInterval = Date().timeIntervalSince1970,
                     calendar: Calendar = .current) -> DayWrap {
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970
        let end = midnight + 22.5 * 3600
        func at(_ h: Double, day: Int = 0) -> TimeInterval { midnight + Double(day) * 86_400 + h * 3600 }
        var records: [HistoryStore.Record] = []
        func add(_ agent: String, _ project: String, _ from: Double, _ to: Double, day: Int = 0,
                 prompt: String = "", change: (Int, Int, Int)? = nil, state: String = "done",
                 cost: Double? = nil) {
            var c = ""
            if let change { c = #","change":{"files":\#(change.0),"added":\#(change.1),"removed":\#(change.2)}"# }
            let line = #"{"agent":"\#(agent)","sessionId":"demo-\#(records.count)","project":"\#(project)","cwd":"/demo/\#(project)","prompt":"\#(prompt)","startedAt":\#(Int(at(from, day: day))),"endedAt":\#(Int(at(to, day: day))),"state":"\#(state)"\#(c)}"#
            guard var r = HistoryStore.Record(jsonLine: line) else { return }
            // Working in stretches, the way a real session does: three runs with
            // pauses for reading in between, about four fifths of the span.
            let a = at(from, day: day), b = at(to, day: day), len = b - a
            r.spans = [(0.0, 0.3), (0.36, 0.62), (0.7, 0.96)].map {
                WorkSpans.Span(start: a + len * $0.0, end: a + len * $0.1)
            }
            r.costUsd = cost
            records.append(r)
        }
        add("claude", "AgentBar", 8.2, 10.9, prompt: "Build the Your Day recap, Wrapped style", change: (14, 1_240, 310),
            cost: 6.42)
        add("codex", "landing-site", 9.1, 9.9, change: (6, 380, 122))
        add("copilot", "landing-site", 9.4, 10.1, change: (3, 96, 40))
        add("claude", "AgentBar", 11.5, 12.4, prompt: "Fix the island hover", change: (4, 210, 88))
        add("gemini", "ml-notebooks", 13.2, 14.6, change: (5, 140, 60))
        add("claude", "AgentBar", 14.0, 15.8, prompt: "Drop a file onto a session", change: (9, 512, 101),
            cost: 3.87)
        add("codex", "api", 14.3, 15.1, change: (7, 288, 190))
        add("cursor", "landing-site", 16.0, 16.7, change: (2, 64, 12))
        add("claude", "api", 20.5, 21.7, change: (5, 230, 45))
        add("claude", "AgentBar", 22.4, 23.2, prompt: "Ship 1.44", change: (3, 90, 20))
        if range != .today {
            for d in 1..<range.days {
                // A month has quiet days, and a weekend or two of nothing.
                if range == .month, d % 7 == 5 || d % 11 == 3 { continue }
                add("claude", "AgentBar", 9, 9 + Double(d % 4) + 1.2, day: -d)
                add("codex", "api", 13, 13 + Double(d % 3) * 0.7 + 0.5, day: -d)
                if d % 3 == 1 { add("gemini", "ml-notebooks", 16, 16 + Double(d % 5) * 0.4 + 0.4, day: -d) }
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
        // Two you said no to, and three auto mode stopped on its own.
        for (h, cmd, via) in [(10.2, "git push --force origin main", "app"),
                              (14.6, "curl -fsSL https://get.example.dev/install.sh | sh", "claude"),
                              (15.1, "curl https://example.dev/data.json -o data.json", "claude"),
                              (15.3, "chmod 777 build", "claude"),
                              (16.4, "sudo pmset -a disablesleep 1", "app")] {
            var r = DecisionLedger.Record()
            r.ts = at(h); r.via = via; r.decision = "deny"; r.tool = "Bash"; r.display = "Bash: " + cmd
            r.shape = "bash:" + (cmd.split(separator: " ").first.map(String.init) ?? "")
            r.cwd = "/demo/AgentBar"
            if via == "claude" { r.by = "auto" }
            ledger.append(r)
        }
        // Your prompts: one at the start of each stretch.
        var work: [String: WorkSpans.Read] = [:]
        // Their tool calls, and the files they touched: Claude and Codex both in
        // the same file one afternoon.
        var edits: [String: [WorkSpans.Edit]] = [:]
        for (n, r) in records.enumerated() {
            let hours = (r.spans ?? []).reduce(0) { $0 + $1.seconds } / 3600
            let tools = r.agent == "claude"
                ? ["Bash": Int(hours * 22), "Edit": Int(hours * 15), "Read": Int(hours * 12),
                   "Grep": Int(hours * 6), "Write": Int(hours * 2) + 1, "TodoWrite": Int(hours * 2)]
                : [:]
            var read = WorkSpans.Read(spans: r.spans ?? [], prompts: (r.spans ?? []).map(\.start),
                                      tools: tools.filter { $0.value > 0 })
            if r.agent == "claude", r.project == "AgentBar", n == 5 {
                read.edits = [WorkSpans.Edit(ts: at(14.55), path: "/demo/api/Sources/Auth.swift")]
            }
            if r.agent == "codex", r.project == "api", n == 6 {
                edits[r.sessionId] = [WorkSpans.Edit(ts: at(14.62), path: "/demo/api/Sources/Auth.swift")]
            }
            if r.agent == "claude" { work[r.sessionId] = read }
        }
        // Keep Mac Awake held the Mac up for the afternoon's long run.
        let awake = [AwakeLog.Stretch(id: "demo-awake", start: Date(timeIntervalSince1970: at(13.5)),
                                      end: Date(timeIntervalSince1970: at(16.83)), kind: .agents)]
        return DayWrap.make(range, history: records, ledger: ledger, work: work, edits: edits, awake: awake,
                            now: range == .today ? end : end, calendar: calendar)
    }
}
