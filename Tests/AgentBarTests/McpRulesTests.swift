import Foundation
import Testing
@testable import AgentBar

/// MCP calls under rules: a whole server may be refused or watched, never
/// approved, and nothing offers a rule that could never fire.
@Suite struct McpRulesTests {
    @Test func aServerWideShapeCoversOnlyThatServer() {
        #expect(RuleEngine.serverWide("tool:mcp__github__*", covers: "tool:mcp__github__create_issue"))
        #expect(!RuleEngine.serverWide("tool:mcp__github__*", covers: "tool:mcp__githubber__x"))
        #expect(!RuleEngine.serverWide("tool:mcp__github__*", covers: "tool:mcp__github__"))
        #expect(RuleEngine.serverPrefix("tool:mcp__*__*") == nil)
        #expect(RuleEngine.serverPrefix("bash:git *") == nil)
    }

    @Test func aWatchingServerDenialSaysWhatItWouldHaveDone() {
        let rule = RulesStore.Rule(id: "r", decision: "deny", shape: "tool:mcp__slack__*", cwd: "",
                                   mode: .watch)
        #expect(RuleEngine.matches(rule, shape: "tool:mcp__slack__post_message", agent: "claude", cwd: "/x"))
    }

    @Test func theSheetWillNotWriteAnApprovalThatCanNeverAnswer() {
        let rule = RulesStore.Rule(id: "r-1", decision: "allow", shape: "tool:mcp__github__get_issue",
                                   cwd: "/work/proj")
        guard case .failure(let why) = RuleSheet.finalised(rule) else {
            Issue.record("an MCP approval was saved"); return
        }
        #expect(why.text.contains("names no file"))
        let deny = RulesStore.Rule(id: "r-2", decision: "deny", shape: "tool:mcp__github__*", cwd: "")
        #expect((try? RuleSheet.finalised(deny).get()) != nil)
    }

    @Test func noOfferOfAnApprovalForAToolThatNamesNoFile() {
        let always = DecisionLedger.Summary(allowed: 9, denied: 0)
        #expect(DecisionLedger.ruleOffer(always, shape: "tool:mcp__github__get_issue", cwd: "/w") == nil)
        #expect(DecisionLedger.ruleOffer(always, shape: "bash:npm test", cwd: "/w") == "allow")
        #expect(DecisionLedger.ruleOffer(always, shape: "bash:npm test", cwd: "") == nil)
        let never = DecisionLedger.Summary(allowed: 0, denied: 9)
        #expect(DecisionLedger.ruleOffer(never, shape: "tool:mcp__github__get_issue", cwd: "/w") == "deny")
    }

    @Test func anMcpCallShowsItsArguments() {
        let lines = ApprovalContextView.argumentLines(#"{"repo":"a/b","body":"line one\nline two","n":3}"#)
        #expect(lines == ["body: line one line two", "n: 3", "repo: a/b"])
        #expect(!ApprovalContextView.hasArguments("{}"))
        // Cut at 4 KB by the hook, so no longer JSON: shown as it came.
        #expect(ApprovalContextView.argumentLines("{\n  \"q\": \"abc") == ["{", "  \"q\": \"abc"])
    }
}
