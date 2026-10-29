import Foundation
import Testing
@testable import AgentBar

/// Over the shoulder: the current turn's tools and words, from the transcript's end.
@Suite struct LiveFeedTests {
    private func lines(_ raw: [String]) -> [Substring] { raw.map { Substring($0) } }

    @Test func theCurrentTurnOnlyNewestLast() {
        let feed = LiveFeed.items(lines([
            #"{"type":"user","message":{"role":"user","content":"old task"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/Old.swift"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"fix the tests"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Let me look."},{"type":"tool_use","name":"Read","input":{"file_path":"/x/Session.swift"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<system-reminder>x</system-reminder>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<task-notification>done</task-notification>"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"swift test\necho done"}},{"type":"tool_use","name":"TodoWrite","input":{}}]}}"#,
        ]))
        #expect(feed == [.said("Let me look."), .tool("Read", "Session.swift"), .tool("Bash", "swift test")])
    }

    @Test func eachToolSaysItsArgument() {
        #expect(LiveFeed.tool("Grep", ["pattern": "isWorking"]) == .tool("Grep", "isWorking"))
        #expect(LiveFeed.tool("WebFetch", ["url": "https://docs.example.com/a"]) == .tool("WebFetch", "docs.example.com"))
        #expect(LiveFeed.tool("Agent", ["description": "find auth code"]) == .tool("Agent", "find auth code"))
        #expect(LiveFeed.tool("mcp__github__create_issue", [:]) == .tool("create_issue", ""))
        #expect(LiveFeed.tool("TaskUpdate", [:]) == nil)
    }

    // MARK: - Peek at output

    private let prompt = #"{"type":"user","message":{"role":"user","content":"run it"}}"#
    private func bash(_ id: String, _ cmd: String) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"Bash","input":{"command":"\#(cmd)"}}]}}"#
    }
    private func result(_ id: String, _ content: String, error: Bool = false) -> String {
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","is_error":\#(error),"content":\#(content)}]}}"#
    }

    @Test func outputIsMatchedToItsCommandById() {
        let feed = LiveFeed.feed(lines([
            prompt,
            bash("a", "ls"), bash("b", "make"),
            // Results arrive out of order; each finds its own call.
            result("b", #""built\n""#), result("a", #""one\ntwo""#),
        ]))
        #expect(feed.items == [.tool("Bash", "ls"), .tool("Bash", "make")])
        // The newest command with a result wins, not the newest result line.
        #expect(feed.output == LiveFeed.Output(lines: ["built"], isError: false, after: 1))
    }

    @Test func noResultNoOutput() {
        let feed = LiveFeed.feed(lines([prompt, bash("a", "sleep 9")]))
        #expect(feed.output == nil)
        #expect(LiveFeed.feed(lines([prompt, bash("a", "x"), result("zz", #""orphan""#)])).output == nil)
    }

    @Test func blockContentAndStringContentReadAlike() {
        let feed = LiveFeed.feed(lines([
            prompt, bash("a", "git status"),
            result("a", #"[{"type":"text","text":"On branch main"},{"type":"image","source":{}},{"type":"text","text":"nothing to commit"}]"#),
        ]))
        #expect(feed.output?.lines == ["On branch main", "nothing to commit"])
    }

    @Test func lastThreeNonEmptyLinesWithoutEscapes() {
        let tail = LiveFeed.outputTail("1\n2\n\n  \n\u{1B}[32m3 ok\u{1B}[0m\n4\t done\n\n\u{1B}]0;title\u{07}5\n\n")
        #expect(tail == ["3 ok", "4   done", "5"])
        #expect(LiveFeed.outputTail("10%\r50%\r100%") == ["100%"])
        #expect(LiveFeed.outputTail(nil).isEmpty)
        #expect(LiveFeed.stripANSI("\u{1B}[1;31mred\u{1B}[K") == "red")
    }

    @Test func aFailedCommandSaysSo() {
        let feed = LiveFeed.feed(lines([prompt, bash("a", "false"), result("a", #""Exit code 1""#, error: true)]))
        #expect(feed.output == LiveFeed.Output(lines: ["Exit code 1"], isError: true, after: 0))
    }

    @Test func aResultFromAnEarlierTurnIsNotShown() {
        let feed = LiveFeed.feed(lines([
            prompt, bash("a", "ls"), result("a", #""old""#),
            #"{"type":"user","message":{"role":"user","content":"now the tests"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"On it."}]}}"#,
            // A late result for the old call does not count either.
            result("a", #""late""#),
        ]))
        #expect(feed.items == [.said("On it.")])
        #expect(feed.output == nil)
    }

    @Test func theFeedStaysWithinSixLines() {
        let feed = LiveFeed.feed(lines([
            prompt,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"First."},{"type":"text","text":"Second."}]}}"#,
            bash("a", "make"), result("a", #""1\n2\n3\n4""#),
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}"#,
        ]))
        #expect(feed.items == [.said("Second."), .tool("Bash", "make"), .said("Done.")])
        #expect(feed.output == LiveFeed.Output(lines: ["2", "3", "4"], isError: false, after: 1))
        // The command scrolled off the top: its output goes with it.
        let gone = LiveFeed.feed(lines([
            prompt, bash("a", "make"), result("a", #""x""#),
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"},{"type":"text","text":"c"},{"type":"text","text":"d"}]}}"#,
        ]))
        #expect(gone.output == nil)
    }

    @Test func longWordsEndAtTheLastSentence() {
        let text = String(repeating: "word ", count: 40) + "First part. And this is the end."
        #expect(LiveFeed.lastWords(text) == "And this is the end.")
        #expect(LiveFeed.lastWords("a\nb") == "a b")
    }

    // MARK: - Calm by default

    @Test func theCdAgentsPutInFrontIsLeftOut() {
        #expect(LiveFeed.withoutCd(#"cd "/Users/me/My Repo" && swift test"#) == "swift test")
        #expect(LiveFeed.withoutCd("cd /a; cd b && make") == "make")
        #expect(LiveFeed.withoutCd("cd '/x y' && git status") == "git status")
        #expect(LiveFeed.withoutCd("cd /tmp") == "cd /tmp")
        #expect(LiveFeed.withoutCd("ls && cd x") == "ls && cd x")
        #expect(LiveFeed.tool("Bash", ["command": "cd \"/r\" && npm test\nmore"]) == .tool("Bash", "npm test"))
    }

    @Test func calmKeepsTheNewestStepAndWordsAndOnlyAFailure() {
        let items: [LiveFeed.Item] = [.tool("Read", "A.swift"), .tool("Bash", "swift test"),
                                      .said("Running them."), .tool("Edit", "B.swift")]
        let ok = LiveFeed.calm(.init(items: items, output: .init(lines: ["a", "b", "c"], isError: false, after: 1)))
        #expect(ok.items == [.said("Running them."), .tool("Edit", "B.swift")])
        #expect(ok.output == nil)
        let failedLast: [LiveFeed.Item] = [.said("Building."), .tool("Bash", "npm run build")]
        let bad = LiveFeed.calm(.init(items: failedLast, output: .init(lines: ["x", "y", "z"], isError: true, after: 1)))
        #expect(bad.items == failedLast)
        #expect(bad.output == .init(lines: ["y", "z"], isError: true, after: 1))
        // A failure under a step that is no longer the newest goes with it.
        let gone = LiveFeed.calm(.init(items: items, output: .init(lines: ["x"], isError: true, after: 1)))
        #expect(gone.output == nil)
        #expect(LiveFeed.calm(.init(items: [])).isEmpty)
    }

    @Test func subagentsShareOneLine() {
        let a = ModReport.Subagent(type: "Explore", what: "find it", model: "")
        let b = ModReport.Subagent(type: "code-reviewer", what: "review", model: "")
        #expect(SubagentLine.summary([], now: 0) == nil)
        #expect(SubagentLine.summary([a], now: 0) == "find it")
        #expect(SubagentLine.summary([a, b, a], now: 0) == "find it  +2")
        #expect(SubagentLine.summary([ModReport.Subagent(type: "Explore")], now: 0) == "Explore")
    }

    @Test func theModelChipOnlyWhenTwoRowsNameDifferentModels() {
        #expect(!IslandController.modelsDiffer(["opus-5-5", nil, nil]))
        #expect(!IslandController.modelsDiffer(["opus-5-5", "opus-5-5"]))
        #expect(IslandController.modelsDiffer(["opus-5-5", nil, "sonnet-5-5"]))
        #expect(!IslandController.modelsDiffer([]))
    }
}
