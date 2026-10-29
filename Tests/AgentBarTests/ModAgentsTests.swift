import Foundation
import Testing
@testable import AgentBar

/// What the mod says about each subagent, and what the session cost.
@Suite struct ModAgentsTests {
    @Test func theReportCarriesEachSubagentAndTheCost() throws {
        let json = """
        {"v":1,"agent":"claude","session_id":"s","ts":1791146583,"subagents":1,
         "agents":[{"type":"Explore","what":"list files","model":"claude-haiku-5-5","background":true,"since":1791146500},
                   {"what":"no type"}],
         "failed_agents":2,"cost_usd":0.4213,"decisions":[]}
        """
        let r = try #require(ModReport.decode(Data(json.utf8), sessionId: "s"))
        #expect(r.agents == [ModReport.Subagent(type: "Explore", what: "list files", model: "claude-haiku-5-5",
                                                background: true, since: 1791146500)])
        #expect(r.failedAgents == 2)
        #expect(r.costUsd == 0.4213)
    }

    @Test func aNegativeOrAbsurdCostIsNotBelieved() throws {
        for c in ["-1", "1e9"] {
            let json = #"{"v":1,"agent":"claude","session_id":"s","ts":1791146583,"cost_usd":"# + c + "}"
            #expect(try #require(ModReport.decode(Data(json.utf8), sessionId: "s")).costUsd == nil)
        }
    }

    @Test func costReadsShort() {
        #expect(CostText.short(nil) == nil)
        #expect(CostText.short(0) == nil)
        #expect(CostText.short(0.004) == "<$0.01")
        #expect(CostText.short(0.4213) == "$0.42")
        #expect(CostText.short(12.6) == "$13")
    }

    @Test func aSubagentInALine() {
        let a = ModReport.Subagent(type: "Explore", what: "list files", model: "claude-haiku-5-5",
                                   background: true, since: 1_000)
        #expect(SubagentLine.text(a, now: 1_150) == "Explore · list files · haiku · 2m · background")
        #expect(SubagentLine.text(ModReport.Subagent(type: "fork"), now: 0) == "fork")
    }
}
