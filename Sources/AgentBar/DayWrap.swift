import Foundation

/// Your day — or week — with your agents, as a handful of facts worth a slide each.
///
/// The recap's model, and only that: pure functions over records already loaded
/// from `history.jsonl` and `decisions.jsonl`, so every number on the cards can be
/// tested and none of them is computed in a view. It follows `HistoryDigest`'s
/// rules, because a recap is the place a number is most likely to be quoted:
/// a figure measured on some sessions says so ("across 4"), a fact with nothing
/// behind it leaves its slide out, and nothing is ever estimated to fill a gap.
struct DayWrap: Equatable {
    enum Range: String, Equatable, CaseIterable {
        case today, week
        var title: String { self == .today ? "Your day" : "Your week" }
    }

    struct AgentShare: Equatable {
        let id: String
        let name: String
        var seconds: TimeInterval
        var sessions: Int
    }

    struct ProjectShare: Equatable {
        let name: String
        var seconds: TimeInterval
        var sessions: Int
    }

    struct Longest: Equatable {
        let agent: String
        let project: String
        /// The prompt the run started from, or its last label — "" when neither.
        let task: String
        let seconds: TimeInterval
    }

    struct Waits: Equatable {
        /// Decisions you made yourself, and how long agents sat waiting on them.
        var answered = 0
        var waited: TimeInterval = 0
        /// Decisions a rule you wrote made for you.
        var byRules = 0
        var fastest: TimeInterval?
        var median: TimeInterval?
    }

    struct Persona: Equatable {
        let title: String
        let reason: String
        /// An SF Symbol for the card.
        let symbol: String
    }

    var range: Range
    var start: TimeInterval
    var end: TimeInterval

    var sessions = 0
    var failed = 0
    /// Summed session time ("agent time") over the `timed` sessions that carry both
    /// ends. Two agents for an hour each is two hours of it.
    var agentSeconds: TimeInterval = 0
    var timed = 0
    /// Wall-clock time with at least one agent running — the union of the spans.
    var busySeconds: TimeInterval = 0
    var tokens = 0
    var tokensMeasured = 0

    /// Agent time per bin: 24 hours for a day, 7 days for a week. Equal length.
    var bins: [TimeInterval] = []
    /// The agent with the most time in each bin, "" for an empty one.
    var binAgents: [String] = []

    var agents: [AgentShare] = []
    var projects: [ProjectShare] = []
    var longest: Longest?

    var filesChanged = 0
    var linesAdded = 0
    var linesRemoved = 0
    /// How many sessions the line counts come from.
    var changeMeasured = 0

    var waits = Waits()
    /// Every decision in the range, as a moment on the day: when, how long it had
    /// waited, and whether a rule made it. Drawn as dots on a line.
    var moments: [Moment] = []

    struct Moment: Equatable {
        let ts: TimeInterval
        let waited: TimeInterval
        let byRule: Bool
    }
    /// The most sessions running at once, and the first moment it happened.
    var peak = 0
    var peakAt: TimeInterval = 0
    var firstStart: TimeInterval = 0
    var lastEnd: TimeInterval = 0
    /// Week only: the day with the most agent time.
    var bestDay: (start: TimeInterval, seconds: TimeInterval)? {
        guard range == .week, let i = bins.indices.max(by: { bins[$0] < bins[$1] }),
              bins[i] > 0 else { return nil }
        return (binStart(i), bins[i])
    }

    var persona = Persona(title: "The Builder", reason: "", symbol: "hammer.fill")

    var isEmpty: Bool { sessions == 0 }
    var topAgent: AgentShare? { agents.first }

    static func == (a: DayWrap, b: DayWrap) -> Bool {
        a.range == b.range && a.start == b.start && a.end == b.end && a.sessions == b.sessions
            && a.agentSeconds == b.agentSeconds && a.agents == b.agents && a.projects == b.projects
            && a.longest == b.longest && a.waits == b.waits && a.peak == b.peak
            && a.persona == b.persona && a.bins == b.bins
    }

    /// Where bin `i` starts.
    func binStart(_ i: Int) -> TimeInterval {
        start + Double(i) * binLength
    }

    var binLength: TimeInterval { range == .today ? 3_600 : 86_400 }

    // MARK: - Building

    /// The span a range covers: today from local midnight, a week as the seven days
    /// ending today. Both end at `now` — a recap is of what has happened.
    static func span(_ range: Range, now: TimeInterval, calendar: Calendar = .current)
    -> (start: TimeInterval, end: TimeInterval) {
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: now))
        switch range {
        case .today:
            return (midnight.timeIntervalSince1970, now)
        case .week:
            let first = calendar.date(byAdding: .day, value: -6, to: midnight) ?? midnight
            return (first.timeIntervalSince1970, now)
        }
    }

    static func make(_ range: Range,
                     history: [HistoryStore.Record],
                     ledger: [DecisionLedger.Record],
                     now: TimeInterval = Date().timeIntervalSince1970,
                     calendar: Calendar = .current) -> DayWrap {
        let (start, end) = span(range, now: now, calendar: calendar)
        var w = DayWrap(range: range, start: start, end: end)
        let records = history.filter { $0.endedAt >= start && $0.endedAt <= end }
        let (summary, _) = HistoryDigest.digest(records, since: start, until: end)
        w.sessions = summary.sessions
        w.failed = summary.failed
        w.tokens = summary.tokens
        w.tokensMeasured = summary.tokensMeasured

        // Spans, clipped to the range: a session that began last night counts for
        // the part of it that was today.
        struct Span { let r: HistoryStore.Record; let from: TimeInterval; let to: TimeInterval }
        let spans: [Span] = records.compactMap { r in
            guard r.startedAt > 0, r.endedAt >= r.startedAt else { return nil }
            let from = max(r.startedAt, start), to = min(r.endedAt, end)
            return to > from ? Span(r: r, from: from, to: to) : nil
        }
        w.timed = spans.count
        w.agentSeconds = spans.reduce(0) { $0 + ($1.to - $1.from) }
        w.firstStart = spans.map(\.from).min() ?? 0
        w.lastEnd = records.map(\.endedAt).max() ?? 0

        // The union, and the peak, in one sweep over the edges.
        var edges: [(t: TimeInterval, d: Int)] = []
        for s in spans { edges.append((s.from, 1)); edges.append((s.to, -1)) }
        // An end before a start at the same instant: back-to-back is not overlap.
        edges.sort { a, b in a.t == b.t ? a.d < b.d : a.t < b.t }
        var running = 0, openedAt: TimeInterval = 0
        for (t, d) in edges {
            if running == 0, d > 0 { openedAt = t }
            running += d
            if running > w.peak { w.peak = running; w.peakAt = t }
            if running == 0 { w.busySeconds += t - openedAt }
        }

        // Bins, with each one's dominant agent.
        let count = range == .today ? 24 : 7
        w.bins = Array(repeating: 0, count: count)
        var perBin = Array(repeating: [String: TimeInterval](), count: count)
        for s in spans {
            for i in 0..<count {
                let b0 = w.binStart(i), b1 = b0 + w.binLength
                let overlap = min(s.to, b1) - max(s.from, b0)
                guard overlap > 0 else { continue }
                w.bins[i] += overlap
                perBin[i][s.r.agent, default: 0] += overlap
            }
        }
        w.binAgents = perBin.map { $0.max { $0.value < $1.value }?.key ?? "" }

        // Who and where. Sessions without a span still count as sessions.
        var byAgent: [String: AgentShare] = [:]
        var byProject: [String: ProjectShare] = [:]
        for r in records {
            let a = r.resolvedAgent
            byAgent[r.agent, default: AgentShare(id: r.agent, name: a.name, seconds: 0, sessions: 0)]
                .sessions += 1
            let name = r.project.isEmpty ? (r.cwd as NSString).lastPathComponent : r.project
            if !name.isEmpty {
                byProject[name, default: ProjectShare(name: name, seconds: 0, sessions: 0)].sessions += 1
            }
        }
        for s in spans {
            byAgent[s.r.agent]?.seconds += s.to - s.from
            let name = s.r.project.isEmpty ? (s.r.cwd as NSString).lastPathComponent : s.r.project
            if !name.isEmpty { byProject[name]?.seconds += s.to - s.from }
        }
        let order: (TimeInterval, Int, String, TimeInterval, Int, String) -> Bool = {
            $0 != $3 ? $0 > $3 : $1 != $4 ? $1 > $4 : $2 < $5
        }
        w.agents = byAgent.values.sorted { order($0.seconds, $0.sessions, $0.id, $1.seconds, $1.sessions, $1.id) }
        w.projects = Array(byProject.values
            .sorted { order($0.seconds, $0.sessions, $0.name, $1.seconds, $1.sessions, $1.name) }
            .prefix(3))

        if let s = spans.max(by: { ($0.to - $0.from) < ($1.to - $1.from) }) {
            let task = !s.r.prompt.isEmpty ? s.r.prompt : s.r.label
            w.longest = Longest(agent: s.r.agent, project: s.r.project,
                                task: oneLine(task), seconds: s.to - s.from)
        }

        for c in records.compactMap(\.change) {
            w.filesChanged += c.files
            w.linesAdded += c.added
            w.linesRemoved += c.removed
            w.changeMeasured += 1
        }

        // Your side of it, from the ledger: the person's own clicks, and the rules
        // they wrote. Claude Code's own decisions and a watching rule's notes are
        // neither, and stay out.
        let inRange = ledger.filter { $0.ts >= start && $0.ts <= end }
        let mine = inRange.filter(\.isPersonal)
        w.waits.answered = mine.count
        w.waits.waited = mine.reduce(0) { $0 + $1.waited }
        w.waits.byRules = DecisionLedger.byRules(in: inRange, since: start, until: end)
        w.moments = inRange.compactMap { r in
            if r.isPersonal { return Moment(ts: r.ts, waited: r.waited, byRule: false) }
            if r.via == "rule", r.decision != "watch" { return Moment(ts: r.ts, waited: 0, byRule: true) }
            return nil
        }
        let waits = mine.map(\.waited).filter { $0 > 0 }.sorted()
        w.waits.fastest = waits.first
        if !waits.isEmpty { w.waits.median = waits[waits.count / 2] }

        w.persona = persona(for: w, calendar: calendar)
        return w
    }

    // MARK: - Persona

    /// Who you were today, by the first rule in this table that holds. Ordered from
    /// the rarest to the most ordinary, so a remarkable day is never called ordinary;
    /// each reason quotes the number that earned it.
    static func persona(for w: DayWrap, calendar: Calendar = .current) -> Persona {
        let day = w.range == .today ? "today" : "this week"
        if w.peak >= 3 {
            return Persona(title: "The Orchestrator",
                           reason: "\(w.peak) agents working at once at \(clock(w.peakAt, calendar)).",
                           symbol: "square.stack.3d.up.fill")
        }
        if let l = w.longest, l.seconds >= 2 * 3_600 {
            return Persona(title: "The Marathoner",
                           reason: "One run went \(HistoryDigest.duration(l.seconds)) without stopping.",
                           symbol: "figure.run")
        }
        let decided = w.waits.answered + w.waits.byRules
        if w.waits.byRules >= 5, Double(w.waits.byRules) >= 0.4 * Double(decided) {
            return Persona(title: "The Delegator",
                           reason: "Your rules answered \(w.waits.byRules) of \(decided) questions \(day).",
                           symbol: "checkmark.seal.fill")
        }
        let night = nightShare(w, calendar)
        if w.agentSeconds >= 1_800, night >= 0.3 {
            return Persona(title: "The Night Owl",
                           reason: "\(Int((night * 100).rounded())) % of the agent time was after 10 pm.",
                           symbol: "moon.stars.fill")
        }
        if w.waits.answered >= 5, let m = w.waits.median, m < 10 {
            return Persona(title: "The Quick Draw",
                           reason: "Half your answers came within \(max(1, Int(m.rounded()))) s.",
                           symbol: "bolt.fill")
        }
        if w.agents.count >= 3 {
            return Persona(title: "The Polyglot",
                           reason: "\(w.agents.count) different agents at work \(day).",
                           symbol: "globe")
        }
        if w.range == .today, w.firstStart > 0,
           calendar.component(.hour, from: Date(timeIntervalSince1970: w.firstStart)) < 7 {
            return Persona(title: "The Early Bird",
                           reason: "The first run started at \(clock(w.firstStart, calendar)).",
                           symbol: "sunrise.fill")
        }
        let time = w.timed > 0 ? " and \(HistoryDigest.duration(w.agentSeconds)) of agent time" : ""
        return Persona(title: "The Builder",
                       reason: "\(w.sessions) session\(w.sessions == 1 ? "" : "s")\(time) \(day).",
                       symbol: "hammer.fill")
    }

    /// The share of agent time between 22:00 and 05:00 local.
    static func nightShare(_ w: DayWrap, _ calendar: Calendar) -> Double {
        guard w.agentSeconds > 0, w.range == .today else { return 0 }
        let night = w.bins.enumerated().filter { $0.offset >= 22 || $0.offset < 5 }
            .reduce(0) { $0 + $1.element }
        return night / w.agentSeconds
    }

    static func clock(_ t: TimeInterval, _ calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: t))
        return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func oneLine(_ s: String, max: Int = 80) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count > max ? String(t.prefix(max - 1)) + "…" : t
    }

    // MARK: - Sharing

    /// The same recap with every name a stranger should not read taken out: the
    /// projects, and the words of the tasks. Agents and numbers stay — they are
    /// the point of sharing it.
    func shareSafe() -> DayWrap {
        var w = self
        w.projects = projects.enumerated().map { i, p in
            ProjectShare(name: ["Project A", "Project B", "Project C"][min(i, 2)],
                         seconds: p.seconds, sessions: p.sessions)
        }
        if let l = longest {
            w.longest = Longest(agent: l.agent, project: l.project.isEmpty ? "" : "a project",
                                task: "", seconds: l.seconds)
        }
        return w
    }
}
