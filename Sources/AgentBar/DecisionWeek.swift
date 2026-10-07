import Foundation

/// "Your week of decisions": which prompts held your agents up most over the last
/// seven days, and what the rules you already wrote did — or, while watching, would
/// have done — about them.
///
/// Pure: the ledger, the rules and the clock come in, a value comes out, and the
/// wording is made here too so it can be tested. `DecisionWeekView` only draws it.
///
/// It reads the ledger the way every other count that is a claim about the person
/// does (`DecisionLedger.Record.isPersonal`): a rule's firing and Claude Code's own
/// decisions are not you being asked, and a watching rule's note is not anything
/// happening. A question (`tool:AskUserQuestion`) is not a permission and no rule
/// speaks for one, so it is left out the way `RuleSheet.offeredShapes` leaves it out.
///
/// **It never writes a rule.** When one would fit, it offers the same sheet the
/// approval card offers — prefilled, starting in Watching, saved only by the
/// person's click. The offer uses the card's own test (`shouldOfferRule`) so the two
/// can never disagree about what "answered the same way" means.
enum DecisionWeek {
    static let span: TimeInterval = 7 * 86_400
    /// How many shapes the list shows. The page is a window, not a report.
    static let shown = 5
    /// Rows the shapes are made of: your verdicts and deferrals. `answer` is a
    /// question's, and a question is not a permission.
    static let counted: Set<String> = ["allow", "always", "deny", "defer"]
    static let question = "tool:AskUserQuestion"

    struct Item: Equatable {
        var shape = ""
        /// Times you were asked and answered in AgentBar.
        var asked = 0
        var waited: TimeInterval = 0
        /// Rows carrying no wait — written by a hook too old to stamp the request —
        /// which make `waited` a floor rather than a total.
        var untimed = 0
        var allowed = 0
        var denied = 0
        var deferred = 0
        /// The newest request line, for the sheet's "From …".
        var display = ""
        /// The directory this was asked in most; what an offered rule is prefilled with.
        var cwd = ""
        var rule: RuleNote?
        /// "allow" | "deny" when no rule has this shape and you answered it the same
        /// way every time — the "Write a rule…" button. Nil otherwise.
        var offer: String?
    }

    /// The rule that has this shape, and what it did with it this week.
    struct RuleNote: Equatable {
        var rule: RulesStore.Rule
        /// Watching: your answers since it started watching that fall where it reaches.
        var reachable = 0
        /// Watching: whether you did what it would have — `DecisionLedger.agreement`,
        /// the evidence "Let it answer" is offered from.
        var agreement = DecisionLedger.Agreement()
        /// Answering: what it answered itself this week.
        var fired = DecisionLedger.Summary()
    }

    struct Week: Equatable {
        /// Where counting starts: seven days ago, or later when the ledger itself
        /// starts later (`startedLate`).
        var since: TimeInterval = 0
        var startedLate = false
        var items: [Item] = []
        /// Shapes asked this week beyond the ones shown.
        var more = 0
        var asked = 0
        var waited: TimeInterval = 0
        var untimed = 0
        /// Answers your rules gave themselves this week.
        var byRules = 0

        var isEmpty: Bool { asked == 0 && byRules == 0 }
    }

    static func make(ledger: [DecisionLedger.Record], rules: [RulesStore.Rule],
                     now: Date = Date()) -> Week {
        let end = now.timeIntervalSince1970
        let start = end - span
        var week = Week(since: start)
        if let first = ledger.map(\.ts).filter({ $0 > 0 }).min(), first > start {
            week.since = first
            week.startedLate = true
        }
        let inWeek = ledger.filter { $0.ts >= start && $0.ts <= end }
        week.byRules = DecisionLedger.byRules(in: inWeek, since: start, until: end)
        let mine = inWeek.filter {
            $0.isPersonal && counted.contains($0.decision) && $0.shape != question
        }

        var groups: [String: [DecisionLedger.Record]] = [:]
        for r in mine { groups[r.shape, default: []].append(r) }

        var items: [Item] = groups.map { shape, rows in
            var item = Item(shape: shape, asked: rows.count)
            for r in rows {
                item.waited += r.waited
                if r.waited < 0.5 { item.untimed += 1 }
                switch r.decision {
                case "allow", "always": item.allowed += 1
                case "deny": item.denied += 1
                default: item.deferred += 1
                }
            }
            item.display = rows.max { $0.ts < $1.ts }?.display ?? ""
            item.cwd = mostAsked(rows)
            return item
        }
        week.asked = items.reduce(0) { $0 + $1.asked }
        week.waited = items.reduce(0) { $0 + $1.waited }
        week.untimed = items.reduce(0) { $0 + $1.untimed }
        items.sort {
            if $0.waited != $1.waited { return $0.waited > $1.waited }
            if $0.asked != $1.asked { return $0.asked > $1.asked }
            return $0.shape < $1.shape
        }
        week.more = max(0, items.count - shown)
        week.items = items.prefix(shown).map { item in
            var item = item
            let rows = groups[item.shape] ?? []
            let candidates = rules.filter { $0.shape == item.shape }
            if let rule = pick(candidates, rows: rows) {
                item.rule = note(rule, rows: rows, inWeek: inWeek, start: start)
            } else {
                item.offer = offer(item, rows: rows)
            }
            return item
        }
        return week
    }

    /// The directory a shape was asked in most; the newest wins a tie.
    private static func mostAsked(_ rows: [DecisionLedger.Record]) -> String {
        var count: [String: (n: Int, last: TimeInterval)] = [:]
        for r in rows {
            let c = count[r.cwd] ?? (0, 0)
            count[r.cwd] = (c.n + 1, max(c.last, r.ts))
        }
        return count.max {
            $0.value.n != $1.value.n ? $0.value.n < $1.value.n : $0.value.last < $1.value.last
        }?.key ?? ""
    }

    /// Whether `rule` reaches a row — `RuleEngine.matches`, with an Off rule asked
    /// as if it were on, because "where would it apply" is the question here.
    static func reaches(_ rule: RulesStore.Rule, _ r: DecisionLedger.Record) -> Bool {
        var live = rule
        if live.mode == .off { live.mode = .watch }
        return RuleEngine.matches(live, shape: r.shape, agent: r.agent, cwd: r.cwd)
    }

    /// Of several rules with one shape, the one reaching most of this week's
    /// prompts; between equals, the one doing most (answering, watching, off).
    private static func pick(_ rules: [RulesStore.Rule],
                             rows: [DecisionLedger.Record]) -> RulesStore.Rule? {
        func rank(_ m: RulesStore.Rule.Mode) -> Int { m == .on ? 2 : m == .watch ? 1 : 0 }
        return rules.max { a, b in
            let ra = rows.filter { reaches(a, $0) }.count
            let rb = rows.filter { reaches(b, $0) }.count
            return ra != rb ? ra < rb : rank(a.mode) < rank(b.mode)
        }
    }

    private static func note(_ rule: RulesStore.Rule, rows: [DecisionLedger.Record],
                             inWeek: [DecisionLedger.Record], start: TimeInterval) -> RuleNote {
        var n = RuleNote(rule: rule)
        switch rule.mode {
        case .watch:
            // Counted from its last save, as the rules list counts it: rows from
            // before an edit were about a rule that no longer exists.
            let from = max(start, rule.created)
            n.reachable = rows.filter { $0.ts >= from && reaches(rule, $0) }.count
            n.agreement = DecisionLedger.agreement(rule: rule.id, in: inWeek, since: rule.created)
        case .on:
            n.fired = DecisionLedger.firings(rule: rule.id, in: inWeek)
        case .off:
            break
        }
        return n
    }

    /// The card's own test, in the directory this was asked in most. An approval
    /// that could never answer is not offered: one with no directory to name, or
    /// one for a tool that names nothing `RuleEngine.refusal` can check.
    private static func offer(_ item: Item, rows: [DecisionLedger.Record]) -> String? {
        let s = DecisionLedger.summary(shape: item.shape, cwd: item.cwd, in: rows)
        guard let way = DecisionLedger.shouldOfferRule(s) else { return nil }
        if way == "allow", item.cwd.isEmpty || item.shape.hasPrefix("tool:") { return nil }
        return way
    }

    /// What "Write a rule…" opens the sheet with. Mode stays the sheet's default,
    /// Watching — the same as every new rule.
    static func prefill(_ item: Item) -> RuleSheet.Prefill? {
        guard let way = item.offer else { return nil }
        return RuleSheet.Prefill(decision: way, shape: item.shape, cwd: item.cwd,
                                 display: item.display)
    }

    // MARK: - Wording

    /// "Last 7 days" — or "Since Tue" when the record itself is younger than that.
    static func span(_ w: Week, now: Date = Date()) -> String {
        w.startedLate ? "Since " + DecisionLedger.ago(Date(timeIntervalSince1970: w.since), now: now)
                      : "Last 7 days"
    }

    /// The card's second line: the totals, and what your rules did on their own.
    static func summary(_ w: Week, now: Date = Date()) -> String {
        var parts = [span(w, now: now)]
        if w.asked > 0 {
            parts.append("asked \(w.asked)×, " + waitPhrase(w.waited, untimed: w.untimed, of: w.asked))
        }
        if w.byRules > 0 { parts.append("your rules answered \(w.byRules) more") }
        return parts.joined(separator: " · ")
    }

    /// "6m waited", "at least 6m waited" when some rows carry no time, and "wait
    /// not recorded" when none do. Never a number dressed up as more than it is.
    static func waitPhrase(_ waited: TimeInterval, untimed: Int, of asked: Int) -> String {
        if untimed >= asked { return "wait not recorded" }
        let d = HistoryDigest.duration(waited)
        return untimed > 0 ? "at least \(d) waited" : "\(d) waited"
    }

    /// The right-hand side of a row: "14× · 6m waited".
    static func figure(_ item: Item) -> String {
        "\(item.asked)× · " + waitPhrase(item.waited, untimed: item.untimed, of: item.asked)
    }

    /// The row's second line: how you answered, then the rule.
    static func detail(_ item: Item, now: Date = Date()) -> String {
        var how: [String] = []
        if item.allowed > 0 { how.append("allowed \(item.allowed)") }
        if item.denied > 0 { how.append("denied \(item.denied)") }
        if item.deferred > 0 { how.append("sent \(item.deferred) to the terminal") }
        let joined = how.joined(separator: ", ")
        let you = joined.prefix(1).uppercased() + joined.dropFirst()
        guard let n = item.rule else {
            return you + (item.offer == nil ? " · no rule" : " · no rule yet")
        }
        return you + " · " + ruleClause(n, now: now)
    }

    /// "allow rule in AgentBar" / "deny rule everywhere".
    static func ruleName(_ r: RulesStore.Rule) -> String {
        "\(r.isAllow ? "allow" : "deny") rule "
            + (r.cwd.isEmpty ? "everywhere" : "in " + (r.cwd as NSString).lastPathComponent)
    }

    static func ruleClause(_ n: RuleNote, now: Date = Date()) -> String {
        // The mode in the words the rules list uses for it, so the two pages
        // name one state one way.
        let name = n.rule.mode.title.lowercased() + " " + ruleName(n.rule)
        switch n.rule.mode {
        case .off:
            return ruleName(n.rule) + " is off"
        case .on:
            let did = n.fired.total
            return did == 0 ? "\(name) took none this week" : "\(name) took \(did) itself"
        case .watch:
            let a = n.agreement
            guard n.reachable > 0 else { return "\(name) has met none of these yet" }
            // Each of your answers pairs with at most one of its notes, so this
            // cannot exceed what you answered — clamped anyway, because a number
            // larger than its "of" is not one anybody should have to read.
            let would = min(a.witnessed, n.reachable)
            var text = "\(name) would have answered \(would) of \(n.reachable)"
            if a.agreed > 0, a.agreedWaited >= 0.5 {
                text += a.agreedWaited < 60 ? ", under a minute"
                                            : ", about " + HistoryDigest.duration(a.agreedWaited)
            }
            if a.disagreed > 0 { text += " · you went the other way \(a.disagreed)×" }
            return text
        }
    }

    /// The empty card's sentence.
    static func emptyText(ledgerOn: Bool) -> String {
        ledgerOn
            ? "Nothing asked you in the last 7 days. A prompt you answer in AgentBar is counted here."
            : "Remember what I decided is off, so no new answer is counted."
    }
}
