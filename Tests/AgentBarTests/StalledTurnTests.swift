import Foundation
import Testing
@testable import AgentBar

/// A Claude Code row stuck on "working" after its turn ended, and the disk that
/// usually causes it.
@Suite struct StalledTurnTests {
    private let use = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash"}]}}"#
    private let result = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ENOSPC"}]}}"#
    private let prompt = #"{"type":"user","message":{"content":"fix the deploy"}}"#

    @Test func aToolWithoutItsResultIsStillRunning() {
        #expect(StalledTurn.toolOutstanding([Substring(prompt), Substring(use)]))
        #expect(!StalledTurn.toolOutstanding([Substring(prompt), Substring(use), Substring(result)]))
        #expect(!StalledTurn.toolOutstanding([Substring(prompt)]))
        #expect(!StalledTurn.toolOutstanding(["{\"type\":\"user\",\"mess"]), "a torn line is not a running tool")
    }

    @Test func onlyAQuietRowOverAQuietTranscriptWithNothingRunningIsStalled() {
        let q = StalledTurn.quiet
        #expect(StalledTurn.isStalled(working: true, rowAge: q, transcriptAge: q, toolOutstanding: false))
        #expect(!StalledTurn.isStalled(working: true, rowAge: q, transcriptAge: q, toolOutstanding: true),
                "a long build is a tool still waiting for its result")
        #expect(!StalledTurn.isStalled(working: true, rowAge: q - 1, transcriptAge: q, toolOutstanding: false))
        #expect(!StalledTurn.isStalled(working: true, rowAge: q, transcriptAge: 30, toolOutstanding: false),
                "the transcript moved: the turn is alive")
        #expect(!StalledTurn.isStalled(working: true, rowAge: q, transcriptAge: nil, toolOutstanding: false),
                "no transcript, no guess")
        #expect(!StalledTurn.isStalled(working: false, rowAge: q, transcriptAge: q, toolOutstanding: false))
    }

    @Test func diskCheckWarnsBeforeItIsFull() {
        #expect(Diagnostics.diskCheck(free: 500_000_000).status == .fail)
        #expect(Diagnostics.diskCheck(free: 500_000_000).detail == "0.5 GB free.")
        #expect(Diagnostics.diskCheck(free: 2_800_000_000).status == .warn)
        #expect(Diagnostics.diskCheck(free: 80_000_000_000).status == .ok)
        #expect(Diagnostics.diskCheck(free: 80_000_000_000).detail == "80 GB free.")
        #expect(Diagnostics.diskCheck(free: nil).status == .skipped)
    }
}
