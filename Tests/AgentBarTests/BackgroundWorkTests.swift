import Foundation
import Testing
@testable import AgentBar

/// A finished turn that left work running says so.
@Suite struct BackgroundWorkTests {
    @Test func aDoneTurnSaysWhatItLeftRunning() {
        let w = BackgroundWork([["type": "shell", "what": "npm run dev"],
                                ["type": "subagent", "what": "Explore"],
                                ["type": "shell", "what": "tail -f log"]], wakeups: 1)
        #expect(w?.text == "3 still running · shell, subagent · wakes again later")
        #expect(w?.detail == "shell: npm run dev\nsubagent: Explore\nshell: tail -f log")
    }

    @Test func nothingLeftRunningIsNoLine() {
        #expect(BackgroundWork([[String: Any]](), wakeups: 0) == nil)
        #expect(BackgroundWork(nil, wakeups: nil) == nil)
        #expect(BackgroundWork([["what": "no type"]], wakeups: nil) == nil)
    }

    @Test func theSessionReadsIt() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bg-\(UUID().uuidString).json")
        try? Data("""
        {"sessionId":"s","agent":"claude","state":"done","ts":1,
         "background":[{"type":"monitor","what":"CI"}],"wakeups":2}
        """.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Session(fileURL: url)?.background?.text == "1 still running · monitor · 2 wakeups scheduled")
    }
}
