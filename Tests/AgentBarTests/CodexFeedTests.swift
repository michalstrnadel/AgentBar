import Foundation
import Testing
@testable import AgentBar

/// Over the shoulder for Codex: the current turn read out of a rollout's end.
/// The lines are written for these tests in the shapes measured on Codex CLI
/// 0.92–0.157 rollouts; none is copied from a real session.
@Suite struct CodexFeedTests {
    private func lines(_ raw: [String]) -> [Substring] { raw.map { Substring($0) } }

    /// 0.153+: calls arrive as JavaScript `exec` cells, and `item_completed` repeats
    /// them after they finish — which must not show twice.
    @Test func codeModeCellsInTheCurrentTurnOnly() {
        let feed = CodexFeed.items(lines([
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"task_started","turn_id":"a"}}"#,
            #"{"timestamp":"t","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c0","input":"text(await tools.exec_command({cmd:\"ls old\"}))"}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"task_started","turn_id":"b"}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"fix the build"}]}}}"#,
            #"{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fix the build"}]}}"#,
            #"{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I'll run the tests first."}],"phase":"commentary"}}"#,
            #"{"timestamp":"t","type":"response_item","payload":{"type":"reasoning","summary":[],"encrypted_content":"x"}}"#,
            #"{"timestamp":"t","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c1","input":"text(await tools.exec_command({cmd:\"swift test --filter \\\"Feed\\\"\\necho ok\",yield_time_ms:1000}))"}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"call_9","command":["/bin/zsh","-lc","swift test"],"status":"completed"}}}"#,
            #"{"timestamp":"t","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":[{"type":"input_text","text":"Script completed"}]}}"#,
            #"{"timestamp":"t","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c2","input":"text(await tools.apply_patch(\"*** Begin Patch\\n*** Update File: /repo/Sources/App/Main.swift\\n@@\\n-a\\n+b\\n*** End Patch\"))"}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","changes":{"/repo/Sources/App/Main.swift":{"type":"update"}},"status":"completed"}}}"#,
            #"{"timestamp":"t","type":"response_item","payload":{"type":"function_call","name":"wait","arguments":"{\"cell_id\":\"3\"}","call_id":"c3"}}"#,
        ]))
        #expect(feed == [
            .said("I'll run the tests first."),
            .tool("Shell", #"swift test --filter "Feed""#),
            .tool("Edit", "Main.swift"),
        ])
    }

    /// 0.92–0.106: direct function calls, a raw patch, and `user_message` as the
    /// turn's start where `task_started` does not exist yet.
    @Test func olderDirectCalls() {
        let feed = CodexFeed.items(lines([
            #"{"type":"event_msg","payload":{"type":"user_message","message":"old"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell_command","arguments":"{\"command\":\"ls\"}","call_id":"a"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"install it"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"Checking first."}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Checking first."}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"brew install x\",\"workdir\":\"/w\"}","call_id":"b"}}"#,
            #"{"type":"response_item","payload":{"type":"web_search_call","status":"completed","action":{"type":"open_page","url":"https://example.com/docs"}}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","call_id":"c","input":"*** Begin Patch\n*** Add File: /w/a.txt\n+x\n*** Update File: /w/b.txt\n*** End Patch"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"make\"]}","call_id":"d"}}"#,
        ]))
        #expect(feed == [
            .tool("Shell", "brew install x"),
            .tool("Web", "example.com"),
            .tool("Edit", "a.txt +1"),
            .tool("Shell", "make"),
        ])
    }

    @Test func callsSayTheirArgumentAndBookkeepingIsLeftOut() {
        #expect(CodexFeed.call("spawn_agent", ["task_name": "review deps", "message": "…"]) == .tool("Agent", "review deps"))
        #expect(CodexFeed.call("send_message", ["target": "/root/review"]) == .tool("Message", "/root/review"))
        #expect(CodexFeed.call("wait", ["cell_id": "1"]) == nil)
        #expect(CodexFeed.call("write_stdin", [:]) == nil)
        #expect(CodexFeed.call("mystery", [:]) == .tool("mystery", ""))
    }

    @Test func aCellWithSeveralCallsKeepsTheirOrder() {
        let js = #"const a = await tools.exec_command({cmd:"git status"}); await tools.write_stdin({session_id:1}); await tools.web__run({q:"x"}); const v = cmd; await tools.exec_command({cmd: v})"#
        #expect(CodexFeed.cell(js) == [.tool("Shell", "git status"), .tool("Web", ""), .tool("Shell", "")])
    }

    @Test func atMostFourNewestLast() {
        let calls = (1...6).map { #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"step \#($0)\"}"}}"# }
        let feed = CodexFeed.items(lines(calls))
        #expect(feed.count == LiveFeed.maxItems)
        #expect(feed.last == .tool("Shell", "step 6"))
    }

    @Test func aRolloutIsFoundByThreadIdAndRead() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codexfeed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let day = home.appendingPathComponent("sessions/2026/10/29")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let body = [
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"npm test\"}"}}"#,
        ].joined(separator: "\n") + "\n"
        let url = day.appendingPathComponent("rollout-2026-10-29T10-00-00-feed-thread.jsonl")
        try body.write(to: url, atomically: true, encoding: .utf8)
        #expect(WeightReader.rollout(id: "feed-thread", base: home)?.lastPathComponent == url.lastPathComponent)
        #expect(CodexFeed.items(LiveFeed.tail(url)) == [.tool("Shell", "npm test")])
    }
}
