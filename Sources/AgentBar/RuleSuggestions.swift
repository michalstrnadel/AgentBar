import Foundation

/// Rules worth writing, read out of what you already decided: a prompt you have
/// answered the same way every time, often enough to be a habit (`ruleOffer`,
/// the card's own test), in the directory you answered it in, that no rule of
/// yours covers yet. Shown on Settings ▸ Rules as an offer; "Write it…" opens the
/// sheet in Watching, and nothing exists until the person presses Add.
///
/// Only the person's own rows count. A rule's answers, Claude Code's own
/// decisions and anything the agent suggested (`ruleSuggestion`) never do: a rule
/// must never originate in what the thing it guards produced.
enum RuleSuggestions {
    struct Suggestion: Equatable {
        let shape: String
        let cwd: String
        let decision: String
        let count: Int
        let lastAt: TimeInterval
        let display: String

        var key: String { "\(shape)|\(cwd)" }
    }

    /// How far back the habit is read.
    static let window: TimeInterval = 30 * 86_400
    static let dismissedKey = "dismissedRuleSuggestions"

    static func make(ledger: [DecisionLedger.Record], rules: [RulesStore.Rule],
                     dismissed: Set<String>, now: Date = Date()) -> [Suggestion] {
        let start = now.timeIntervalSince1970 - window
        let rows = ledger.filter {
            $0.ts >= start && $0.isPersonal && !$0.cwd.isEmpty
                && $0.shape != "tool:AskUserQuestion"
                && ["allow", "always", "deny"].contains($0.decision)
        }
        var groups: [String: [DecisionLedger.Record]] = [:]
        for r in rows { groups["\(r.shape)|\(r.cwd)", default: []].append(r) }

        var out: [Suggestion] = []
        for (key, group) in groups where !dismissed.contains(key) {
            let first = group[0]
            let summary = DecisionLedger.summary(shape: first.shape, cwd: first.cwd, in: group)
            guard let way = DecisionLedger.ruleOffer(summary, shape: first.shape, cwd: first.cwd),
                  !covered(first.shape, cwd: first.cwd, by: rules)
            else { continue }
            out.append(Suggestion(shape: first.shape, cwd: first.cwd, decision: way,
                                  count: summary.total, lastAt: summary.lastAt,
                                  display: group.max { $0.ts < $1.ts }?.display ?? first.shape))
        }
        return out.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.lastAt > $1.lastAt
        }
    }

    /// Whether a rule already speaks for this shape here — on, watching or off:
    /// an off rule is a decision about this prompt too, and offering a second one
    /// beside it would be nagging.
    static func covered(_ shape: String, cwd: String, by rules: [RulesStore.Rule]) -> Bool {
        rules.contains { rule in
            (rule.shape == shape || RuleEngine.serverWide(rule.shape, covers: shape))
                && (rule.cwd.isEmpty || cwd == rule.cwd || cwd.hasPrefix(rule.cwd + "/"))
        }
    }

    static func prefill(_ s: Suggestion) -> RuleSheet.Prefill {
        RuleSheet.Prefill(decision: s.decision, shape: s.shape, cwd: s.cwd, display: s.display)
    }

    static var dismissed: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
    }

    static func dismiss(_ s: Suggestion) {
        UserDefaults.standard.set(Array(dismissed.union([s.key])).sorted(), forKey: dismissedKey)
    }
}
