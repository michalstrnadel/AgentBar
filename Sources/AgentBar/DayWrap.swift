import Foundation

/// Your day — or week — with your agents, as a handful of facts on one card.
///
/// The recap's model, and only that: pure functions over records already loaded
/// from `history.jsonl` and `decisions.jsonl`, so every number on the cards can be
/// tested and none of them is computed in a view. It follows `HistoryDigest`'s
/// rules, because a recap is the place a number is most likely to be quoted:
/// a figure measured on some sessions says so ("across 4"), a fact with nothing
/// behind it gets no row, and nothing is ever estimated to fill a gap.
struct DayWrap: Equatable {
    enum Range: String, Equatable, CaseIterable {
        case today, week, month
        var title: String {
            switch self {
            case .today: return "Your day"
            case .week: return "Your week"
            case .month: return "Your month"
            }
        }
        /// How many days it covers, ending today.
        var days: Int {
            switch self {
            case .today: return 1
            case .week: return 7
            case .month: return 30
            }
        }
        /// "today", "this week", "this month" — the end of a persona's sentence.
        var phrase: String {
            switch self {
            case .today: return "today"
            case .week: return "this week"
            case .month: return "this month"
            }
        }
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
        /// Which session, and when the stretch began — for going back to it.
        var sessionId = ""
        var from: TimeInterval = 0
    }

    struct Waits: Equatable {
        /// Decisions you made yourself, and how long agents sat waiting on them.
        var answered = 0
        var waited: TimeInterval = 0
        /// Decisions a rule you wrote made for you.
        var byRules = 0
        /// What Claude Code's auto mode refused. Neither yours nor your rules'.
        var autoRefused = DecisionLedger.AutoRefusals()
        var fastest: TimeInterval?
        var median: TimeInterval?
    }

    /// The Trust Receipt: what the agents did and what was decided about it, as
    /// a till would print it. Every count is measured or absent, like the card's.
    struct Receipt: Equatable {
        /// Tool calls by name, most first — from the sessions whose transcript
        /// says (`toolsMeasured`), never estimated for the rest.
        var tools: [ToolCount] = []
        var toolCalls = 0
        var toolsMeasured = 0
        /// What the sessions cost at API prices, summed over the `costMeasured`
        /// ones that carry a number (`HistoryStore.Record.costUsd`).
        var cost: Double = 0
        var costMeasured = 0
        /// Your own answers: yes (`allow`, `always`) and no.
        var approvals = 0
        var denials = 0
        /// What Claude Code refused by its own settings — a deny rule, the mode —
        /// before anybody was asked. Auto mode's refusals are `Waits.autoRefused`.
        var claudeStopped = 0
        /// The most far-reaching command that was stopped — by you, a rule, or
        /// auto mode. Nil when nothing stopped reached anything.
        var riskiest: Riskiest?
    }

    struct ToolCount: Equatable {
        let name: String
        let count: Int
    }

    /// A stopped Bash command and what `BlastRadius` says it could reach. Read off
    /// the ledger's `display`, which is cut at about 60 characters, so the reach
    /// is a lower bound: the part that was cut could only have reached further.
    struct Riskiest: Equatable {
        var command: String
        /// `BlastRadius` labels, most severe first: "pipes into a shell", "network".
        let reaches: [String]
        let severity: BlastRadius.Severity
        /// The ledger kept only the start of the command.
        let cut: Bool
        /// Who stopped it: "you", "your rule", "auto mode", "a Claude Code rule", "a hook", "Claude Code".
        let by: String
        let ts: TimeInterval
    }

    /// One agent's share of a day, for the skyline's stacked columns.
    struct Slice: Equatable {
        let agent: String
        let seconds: TimeInterval
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
    /// Time agents spent working ("agent time"), summed over the `timed` sessions
    /// whose working stretches are known (`WorkSpans`) — not how long their windows
    /// were open. Two agents working for an hour each is two hours of it.
    var agentSeconds: TimeInterval = 0
    var timed = 0
    /// Wall-clock time with at least one agent running — the union of the spans.
    var busySeconds: TimeInterval = 0
    var tokens = 0
    var tokensMeasured = 0
    /// How long Keep Mac Awake held the Mac up in the range (`AwakeLog`), and how
    /// much of that was "while agents work".
    var keptAwake: TimeInterval = 0
    var keptAwakeForAgents: TimeInterval = 0

    /// Agent time per bin: 24 hours for a day, 7 days for a week. Equal length.
    var bins: [TimeInterval] = []
    /// The agent with the most time in each bin, "" for an empty one.
    var binAgents: [String] = []
    /// What *you* did in each bin: prompts typed and requests answered.
    var youBins: [Int] = []
    /// Prompts typed in the range, where the agent records them (Claude Code).
    var prompts = 0
    /// The bin with the most agent work, and the one with the most of you; nil when empty.
    var busiestBin: Int? { bins.indices.max { bins[$0] < bins[$1] }.flatMap { bins[$0] > 0 ? $0 : nil } }
    var yourBin: Int? { youBins.indices.max { youBins[$0] < youBins[$1] }.flatMap { youBins[$0] > 0 ? $0 : nil } }

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
    /// waited, and whether a rule made it. Not drawn; the card's "you" dots come
    /// from `youBins`.
    var moments: [Moment] = []

    struct Moment: Equatable {
        let ts: TimeInterval
        let waited: TimeInterval
        let byRule: Bool
    }
    /// Two sessions that edited one file minutes apart (`Flyby`), oldest first.
    var crossings: [Flyby.Crossing] = []
    var receipt = Receipt()
    /// Each bin's agent time by agent, in the order of `agents` — the skyline's
    /// stacks. Empty bins are empty arrays.
    var stacks: [[Slice]] = []
    /// Agent time between 22:00 and 05:00 local, and how much of it had two or
    /// more agents at work at once (`nightPeak` at most).
    var nightSeconds: TimeInterval = 0
    var nightTogether: TimeInterval = 0
    var nightPeak = 0
    /// Of the sessions whose prompts are known (Claude Code's transcript): the
    /// longest stretch agents worked with no prompt or answer from you, and all
    /// the work done more than ten minutes after you last touched anything.
    var handsOffLongest: TimeInterval = 0
    var handsOffAt: TimeInterval = 0
    var handsOffSeconds: TimeInterval = 0
    /// The busy time those figures are measured against.
    var handsOffOf: TimeInterval = 0
    /// The most sessions running at once, and the first moment it happened.
    var peak = 0
    var peakAt: TimeInterval = 0
    var firstStart: TimeInterval = 0
    var lastEnd: TimeInterval = 0
    /// Week and month: the day with the most agent time.
    var bestDay: (start: TimeInterval, seconds: TimeInterval)? {
        guard range != .today, let i = bins.indices.max(by: { bins[$0] < bins[$1] }),
              bins[i] > 0 else { return nil }
        return (binStart(i), bins[i])
    }

    var persona = Persona(title: "The Builder", reason: "", symbol: "hammer.fill")

    var isEmpty: Bool { sessions == 0 }
    /// Still being added up. A card that is drawn before the numbers are in must
    /// say so — drawn as an empty recap it read "A quiet day" under the date of
    /// 1 January 1970 for as long as a long transcript took to read.
    var pending = false

    /// The card shown while the real one is read: the right dates, no numbers.
    static func placeholder(_ range: Range, now: TimeInterval = Date().timeIntervalSince1970,
                            calendar: Calendar = .current) -> DayWrap {
        let (start, end) = span(range, now: now, calendar: calendar)
        var w = DayWrap(range: range, start: start, end: end)
        w.pending = true
        return w
    }
    var topAgent: AgentShare? { agents.first }

    static func == (a: DayWrap, b: DayWrap) -> Bool {
        a.range == b.range && a.start == b.start && a.end == b.end && a.sessions == b.sessions
            && a.agentSeconds == b.agentSeconds && a.agents == b.agents && a.projects == b.projects
            && a.longest == b.longest && a.waits == b.waits && a.peak == b.peak
            && a.persona == b.persona && a.bins == b.bins && a.keptAwake == b.keptAwake
            && a.receipt == b.receipt && a.crossings == b.crossings && a.stacks == b.stacks
            && a.nightSeconds == b.nightSeconds && a.nightTogether == b.nightTogether
            && a.handsOffLongest == b.handsOffLongest && a.handsOffSeconds == b.handsOffSeconds
    }

    /// Where bin `i` starts.
    func binStart(_ i: Int) -> TimeInterval {
        start + Double(i) * binLength
    }

    var binLength: TimeInterval { range == .today ? 3_600 : 86_400 }

    // MARK: - Building

    /// The span a range covers: today from local midnight, a week as the seven days
    /// ending today, a month as the thirty. All end at `now` — a recap is of what
    /// has happened.
    static func span(_ range: Range, now: TimeInterval, calendar: Calendar = .current)
    -> (start: TimeInterval, end: TimeInterval) {
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: now))
        switch range {
        case .today:
            return (midnight.timeIntervalSince1970, now)
        case .week, .month:
            let first = calendar.date(byAdding: .day, value: -(range.days - 1), to: midnight) ?? midnight
            return (first.timeIntervalSince1970, now)
        }
    }

    static func make(_ range: Range,
                     history: [HistoryStore.Record],
                     ledger: [DecisionLedger.Record],
                     work: [String: WorkSpans.Read] = [:],
                     edits: [String: [WorkSpans.Edit]] = [:],
                     awake: [AwakeLog.Stretch] = [],
                     now: TimeInterval = Date().timeIntervalSince1970,
                     calendar: Calendar = .current) -> DayWrap {
        let (start, end) = span(range, now: now, calendar: calendar)
        var w = DayWrap(range: range, start: start, end: end)
        let held = AwakeLog.total(awake, in: DateInterval(start: Date(timeIntervalSince1970: start),
                                                          end: Date(timeIntervalSince1970: max(start, end))))
        w.keptAwake = held.all
        w.keptAwakeForAgents = held.agents
        let records = history.filter { $0.endedAt >= start && $0.endedAt <= end }
        let (summary, _) = HistoryDigest.digest(records, since: start, until: end)
        w.sessions = summary.sessions
        w.failed = summary.failed
        w.tokens = summary.tokens
        w.tokensMeasured = summary.tokensMeasured

        // The stretches each session was actually working, clipped to the range:
        // the transcript's when there is one, else what AgentBar saw. A session
        // with neither is counted but untimed — never given its window's span.
        struct Span { let r: HistoryStore.Record; let from: TimeInterval; let to: TimeInterval }
        var spans: [Span] = []
        var timedIDs = Set<String>()
        for r in records {
            guard let known = work[r.sessionId]?.spans ?? r.spans else { continue }
            timedIDs.insert(r.sessionId)
            for s in WorkSpans.clipped(known, from: start, to: end) {
                spans.append(Span(r: r, from: s.start, to: s.end))
            }
        }
        w.timed = timedIDs.count
        w.agentSeconds = spans.reduce(0) { $0 + ($1.to - $1.from) }
        w.firstStart = spans.map(\.from).min() ?? 0
        w.lastEnd = records.map(\.endedAt).max() ?? 0

        // The union, and the peak, in one sweep over the edges.
        var edges: [(t: TimeInterval, d: Int)] = []
        for s in spans { edges.append((s.from, 1)); edges.append((s.to, -1)) }
        // An end before a start at the same instant: back-to-back is not overlap.
        edges.sort { a, b in a.t == b.t ? a.d < b.d : a.t < b.t }
        var running = 0, openedAt: TimeInterval = 0, last: TimeInterval = 0
        for (t, d) in edges {
            // Between two edges the count holds: two or more at night is the
            // night shift, and it counts only the night part of the stretch.
            if running >= 2, t > last {
                let night = nightSeconds(from: last, to: t, calendar)
                if night > 0 { w.nightTogether += night; w.nightPeak = max(w.nightPeak, running) }
            }
            last = t
            if running == 0, d > 0 { openedAt = t }
            running += d
            if running > w.peak { w.peak = running; w.peakAt = t }
            if running == 0 { w.busySeconds += t - openedAt }
        }
        w.nightSeconds = spans.reduce(0) { $0 + nightSeconds(from: $1.from, to: $1.to, calendar) }

        // Bins, with each one's dominant agent.
        let count = range == .today ? 24 : range.days
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
        // The skyline's stacks, each bin in the order of the agents above, so a
        // colour sits at the same height in every column.
        let rank = Dictionary(uniqueKeysWithValues: w.agents.enumerated().map { ($1.id, $0) })
        w.stacks = perBin.map { bin in
            bin.filter { $0.value > 0 }
                .sorted { (rank[$0.key] ?? .max, $0.key) < (rank[$1.key] ?? .max, $1.key) }
                .map { Slice(agent: $0.key, seconds: $0.value) }
        }

        // The longest single stretch of work, not the longest-open window.
        if let s = spans.max(by: { ($0.to - $0.from) < ($1.to - $1.from) }) {
            let task = !s.r.prompt.isEmpty ? s.r.prompt : s.r.label
            w.longest = Longest(agent: s.r.agent, project: s.r.project,
                                task: oneLine(task), seconds: s.to - s.from,
                                sessionId: s.r.sessionId, from: s.from)
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
        w.waits.autoRefused = DecisionLedger.autoRefusals(in: inRange, since: start, until: end)
        w.moments = inRange.compactMap { r in
            if r.isPersonal { return Moment(ts: r.ts, waited: r.waited, byRule: false) }
            if r.via == "rule", r.decision != "watch" { return Moment(ts: r.ts, waited: 0, byRule: true) }
            return nil
        }
        let waits = mine.map(\.waited).filter { $0 > 0 }.sorted()
        w.waits.fastest = waits.first
        if !waits.isEmpty { w.waits.median = waits[waits.count / 2] }

        // You, by the hour: every prompt you typed (where the agent keeps them) and
        // every request you answered yourself.
        w.youBins = Array(repeating: 0, count: count)
        func bin(_ t: TimeInterval) -> Int? {
            guard t >= start, t <= end else { return nil }
            let i = Int((t - start) / w.binLength)
            return i >= 0 && i < count ? i : nil
        }
        let ids = Set(records.map(\.sessionId))
        for (id, read) in work where ids.contains(id) {
            for t in read.prompts { if let i = bin(t) { w.youBins[i] += 1; w.prompts += 1 } }
        }
        for r in mine { if let i = bin(r.ts) { w.youBins[i] += 1 } }

        // Hands off: only where your side is known — the sessions whose transcript
        // has your prompts — or a Codex day would read as a day you were away.
        let known = spans.filter { work[$0.r.sessionId] != nil }
        var touches = mine.map(\.ts).filter { $0 >= start && $0 <= end }
        for (id, read) in work where ids.contains(id) { touches += read.prompts.filter { $0 >= start && $0 <= end } }
        if !known.isEmpty, !touches.isEmpty {
            let h = handsOff(WorkSpans.joined(known.map { WorkSpans.Span(start: $0.from, end: $0.to) }, gap: 0),
                             touches: touches.sorted())
            (w.handsOffLongest, w.handsOffAt, w.handsOffSeconds, w.handsOffOf) = h
        }

        w.receipt = receipt(records: records, inRange: inRange, mine: mine, work: work)
        var events: [Flyby.EditEvent] = []
        for r in records {
            for e in (work[r.sessionId]?.edits ?? []) + (edits[r.sessionId] ?? []) where e.ts >= start && e.ts <= end {
                events.append(Flyby.EditEvent(ts: e.ts, path: e.path, session: r.sessionId, agent: r.agent))
            }
        }
        w.crossings = Flyby.pairs(events: events)

        w.persona = persona(for: w, calendar: calendar)
        return w
    }

    /// How long you can be gone before the work is yours no more: ten minutes
    /// after your last prompt or answer, the agents are on their own.
    static let awayAfter: TimeInterval = 10 * 60

    /// The longest stretch of `busy` with no touch inside it (and where it began),
    /// the busy time more than `awayAfter` past the last touch, and all the busy time.
    static func handsOff(_ busy: [WorkSpans.Span], touches: [TimeInterval])
    -> (longest: TimeInterval, at: TimeInterval, away: TimeInterval, of: TimeInterval) {
        var longest: TimeInterval = 0, at: TimeInterval = 0, away: TimeInterval = 0, of: TimeInterval = 0
        for b in busy {
            of += b.seconds
            // Cut the stretch at every touch inside it.
            var cuts = [b.start] + touches.filter { $0 > b.start && $0 < b.end } + [b.end]
            cuts = Array(Set(cuts)).sorted()
            for (p0, p1) in zip(cuts, cuts.dropFirst()) {
                if p1 - p0 > longest { longest = p1 - p0; at = p0 }
                let lastTouch = touches.last { $0 <= p0 }
                let from = lastTouch.map { max(p0, $0 + awayAfter) } ?? p0
                away += max(0, p1 - from)
            }
        }
        return (longest, at, away, of)
    }

    /// The receipt's lines, from the records and the ledger already in range.
    static func receipt(records: [HistoryStore.Record], inRange: [DecisionLedger.Record],
                        mine: [DecisionLedger.Record], work: [String: WorkSpans.Read]) -> Receipt {
        var r = Receipt()
        var tools: [String: Int] = [:]
        for rec in records {
            guard let t = work[rec.sessionId]?.tools, !t.isEmpty else { continue }
            r.toolsMeasured += 1
            for (k, v) in t { tools[k, default: 0] += v }
        }
        r.tools = tools.map { ToolCount(name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
        r.toolCalls = tools.values.reduce(0, +)
        for rec in records { if let c = rec.costUsd { r.cost += c; r.costMeasured += 1 } }
        r.approvals = mine.filter { $0.decision == "allow" || $0.decision == "always" }.count
        r.denials = mine.filter { $0.decision == "deny" }.count
        r.claudeStopped = inRange.filter { $0.via == "claude" && $0.decision == "deny" && !$0.isAutoRefusal }.count
        r.riskiest = riskiest(inRange)
        return r
    }

    /// The stopped Bash command that reached furthest: highest `BlastRadius`
    /// severity, then the most kinds of reach, then the earliest. Only a command
    /// that reached something — a stopped `ls` is not a risk.
    static func riskiest(_ ledger: [DecisionLedger.Record]) -> Riskiest? {
        var best: (Riskiest, Int)?
        for r in ledger where r.decision == "deny" {
            guard r.tool == "Bash" || r.display.hasPrefix("Bash: ") else { continue }
            var command = r.display.hasPrefix("Bash: ") ? String(r.display.dropFirst(6)) : r.display
            let cut = command.hasSuffix("…") || r.display.count >= 60
            if command.hasSuffix("…") { command = String(command.dropLast()) }
            command = command.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { continue }
            // The cut-off chip says the ledger was short, not that the command was.
            let chips = BlastRadius.ordered(BlastRadius.commandChips(command, cwd: r.cwd))
                .filter { $0.kind != .truncated }
            guard !chips.isEmpty else { continue }
            let by = r.isAutoRefusal ? "auto mode" : r.via == "rule" ? "your rule"
                : r.via == "claude" ? (r.by == "hook" ? "a hook" : r.by == "rule" ? "a Claude Code rule" : "Claude Code")
                : "you"
            let found = Riskiest(command: command, reaches: chips.map(\.label),
                                 severity: BlastRadius.severity(of: chips), cut: cut, by: by, ts: r.ts)
            if let (b, n) = best {
                if (found.severity, chips.count) < (b.severity, n) { continue }
                if (found.severity, chips.count) == (b.severity, n), found.ts >= b.ts { continue }
            }
            best = (found, chips.count)
        }
        return best?.0
    }

    /// The part of `[from, to]` between 22:00 and 05:00 local.
    static func nightSeconds(from: TimeInterval, to: TimeInterval, _ calendar: Calendar) -> TimeInterval {
        guard to > from else { return 0 }
        var total: TimeInterval = 0
        var t = from
        while t < to {
            let date = Date(timeIntervalSince1970: t)
            let hour = calendar.component(.hour, from: date)
            let next = calendar.dateInterval(of: .hour, for: date).map { $0.end.timeIntervalSince1970 } ?? t + 3_600
            let upto = min(to, max(next, t + 1))
            if hour >= 22 || hour < 5 { total += upto - t }
            t = upto
        }
        return total
    }

    /// This Mac's recap: the history and the ledger, plus each Claude session's
    /// transcript for when it was really working. Reads files — off the main queue.
    static func load(_ range: Range, now: TimeInterval = Date().timeIntervalSince1970,
                     calendar: Calendar = .current) -> DayWrap {
        let history = HistoryStore.read()
        let (start, end) = span(range, now: now, calendar: calendar)
        var work: [String: WorkSpans.Read] = [:]
        var edits: [String: [WorkSpans.Edit]] = [:]
        for r in history where r.endedAt >= start && r.endedAt <= end {
            switch r.agent {
            case "claude":
                if let read = WorkSpans.claude(sessionId: r.sessionId, cwd: r.cwd) { work[r.sessionId] = read }
            case "codex":
                let e = CodexFeed.edits(sessionId: r.sessionId, cwd: r.cwd)
                if !e.isEmpty { edits[r.sessionId] = e }
            default:
                break
            }
        }
        return make(range, history: history, ledger: DecisionLedger.read(), work: work, edits: edits,
                    awake: AwakeLog.read(), now: now, calendar: calendar)
    }

    // MARK: - Persona

    /// Who you were today, by the first rule in this table that holds. Ordered from
    /// the rarest to the most ordinary, so a remarkable day is never called ordinary;
    /// each reason quotes the number that earned it.
    static func persona(for w: DayWrap, calendar: Calendar = .current) -> Persona {
        let day = w.range.phrase
        if w.peak >= 3 {
            return Persona(title: "The Orchestrator",
                           reason: "\(w.peak) agents working at once at \(clock(w.peakAt, calendar))"
                               + (w.range != .today ? " on \(weekday(w.peakAt, calendar))." : "."),
                           symbol: "square.stack.3d.up.fill")
        }
        if w.nightTogether >= 30 * 60, w.nightSeconds >= 3_600 {
            return Persona(title: "The Night-Shift Conductor",
                           reason: "\(w.nightPeak) agents at once after 10 pm, "
                               + "for \(HistoryDigest.duration(w.nightTogether)).",
                           symbol: "moon.fill")
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
        if w.handsOffSeconds >= 3_600, w.handsOffSeconds >= 0.5 * w.handsOffOf {
            return Persona(title: "Hands-Off",
                           reason: "Agents worked \(HistoryDigest.duration(w.handsOffSeconds)) of it "
                               + "with nothing from you.",
                           symbol: "hand.raised.slash.fill")
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

    static func weekday(_ t: TimeInterval, _ calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEEE"
        return f.string(from: Date(timeIntervalSince1970: t))
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
                                task: "", seconds: l.seconds, sessionId: l.sessionId, from: l.from)
        }
        // A command line and a file path both name things: the reach and the
        // agents stay, the words go.
        w.receipt.riskiest?.command = ""
        w.crossings = crossings.map { c in
            func bare(_ e: Flyby.EditEvent) -> Flyby.EditEvent {
                Flyby.EditEvent(ts: e.ts, path: "", session: e.session, agent: e.agent)
            }
            return Flyby.Crossing(path: "", first: bare(c.first), second: bare(c.second))
        }
        return w
    }
}
