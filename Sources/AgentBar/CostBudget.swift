import Foundation

/// A per-session budget the person set in Settings ▸ Usage: a session whose cost
/// (`Session.costUsd`, at API prices) has reached it gets an amber cost chip and a
/// line in its tooltip. That is all it does — it never stops, interrupts or answers
/// a session (rule 3) and never puts anything on the screen by itself (rule 2).
/// Off until a positive amount is typed in.
enum CostBudget {
    static let key = "sessionCostBudget"
    /// Anything at or above this is not a budget anybody meant; read as off.
    static let ceiling = 1_000_000.0

    /// The budget in dollars, nil when off.
    static var limit: Double? {
        get { parse(UserDefaults.standard.object(forKey: key)) }
        set {
            if let v = newValue.flatMap({ parse($0) }) { UserDefaults.standard.set(v, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// A stored or typed value as a budget: a positive, finite amount under the
    /// ceiling, from a number or a string ("5", "$5", "2.50", "2,50"). Everything
    /// else — empty, zero, negative, NaN, words — is off.
    static func parse(_ raw: Any?) -> Double? {
        let value: Double?
        switch raw {
        case let n as NSNumber:
            // A stored `true` is an NSNumber too, and would read as $1.
            value = CFGetTypeID(n) == CFBooleanGetTypeID() ? nil : n.doubleValue
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: ".")
                .trimmingCharacters(in: .whitespaces)
            value = Double(t)
        default: value = nil
        }
        guard let v = value, v.isFinite, v > 0, v < ceiling else { return nil }
        return v
    }

    /// True when the cost has reached the budget. No budget or no cost is never over.
    static func isOver(_ cost: Double?, limit: Double? = CostBudget.limit) -> Bool {
        guard let limit, let cost, cost.isFinite else { return false }
        return cost >= limit
    }

    /// "$5", "$2.50" — whole dollars without cents.
    static func amount(_ limit: Double) -> String {
        limit == limit.rounded() ? String(format: "$%.0f", limit) : String(format: "$%.2f", limit)
    }

    /// "over your $5 budget" when `cost` has reached it, nil otherwise.
    static func note(_ cost: Double?, limit: Double? = CostBudget.limit) -> String? {
        guard isOver(cost, limit: limit), let limit else { return nil }
        return "over your \(amount(limit)) budget"
    }
}
