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

    @Test func longWordsEndAtTheLastSentence() {
        let text = String(repeating: "word ", count: 40) + "First part. And this is the end."
        #expect(LiveFeed.lastWords(text) == "And this is the end.")
        #expect(LiveFeed.lastWords("a\nb") == "a b")
    }
}
