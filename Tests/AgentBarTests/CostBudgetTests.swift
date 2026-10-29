import Foundation
import Testing
@testable import AgentBar

/// The per-session budget: off until a positive amount is set, flags a session
/// at or over it, and reads anything it does not understand as off.
@Suite(.serialized)
struct CostBudgetTests {
    @Test func offByDefault() {
        let saved = UserDefaults.standard.object(forKey: CostBudget.key)
        defer { UserDefaults.standard.set(saved, forKey: CostBudget.key) }
        UserDefaults.standard.removeObject(forKey: CostBudget.key)
        #expect(CostBudget.limit == nil)
        #expect(!CostBudget.isOver(1_000))
        #expect(CostBudget.note(1_000) == nil)
    }

    @Test func roundTripAndClearing() {
        let saved = UserDefaults.standard.object(forKey: CostBudget.key)
        defer { UserDefaults.standard.set(saved, forKey: CostBudget.key) }
        CostBudget.limit = 5
        #expect(CostBudget.limit == 5)
        CostBudget.limit = 0
        #expect(CostBudget.limit == nil)
        #expect(UserDefaults.standard.object(forKey: CostBudget.key) == nil)
    }

    @Test func thresholdEdge() {
        #expect(!CostBudget.isOver(4.99, limit: 5))
        #expect(CostBudget.isOver(5, limit: 5))
        #expect(CostBudget.isOver(5.01, limit: 5))
    }

    @Test func noCostIsNeverOver() {
        #expect(!CostBudget.isOver(nil, limit: 5))
        #expect(!CostBudget.isOver(.nan, limit: 5))
        #expect(CostBudget.note(nil, limit: 5) == nil)
    }

    @Test func badPrefValuesAreOff() {
        for raw: Any? in [nil, "", "  ", "abc", "0", 0, -5, "-1", Double.nan, Double.infinity,
                          1_000_000, true, ["5"], Data()] {
            #expect(CostBudget.parse(raw) == nil, "\(String(describing: raw))")
        }
    }

    @Test func goodPrefValues() {
        #expect(CostBudget.parse(5) == 5)
        #expect(CostBudget.parse(2.5) == 2.5)
        #expect(CostBudget.parse("5") == 5)
        #expect(CostBudget.parse(" $5 ") == 5)
        #expect(CostBudget.parse("2,50") == 2.5)
    }

    @Test func theWords() {
        #expect(CostBudget.amount(5) == "$5")
        #expect(CostBudget.amount(2.5) == "$2.50")
        #expect(CostBudget.note(6.2, limit: 5) == "over your $5 budget")
        #expect(CostBudget.note(4, limit: 5) == nil)
    }
}
