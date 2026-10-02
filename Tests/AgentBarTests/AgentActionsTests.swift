import Foundation
import Testing
@testable import AgentBar

/// The inline Allow strip types a keystroke into a terminal on **this** machine.
/// Which sessions may be aimed at is therefore a question about the row, not about
/// the agent — and `docs/protocol.md` lets anybody write a row.
@Suite struct AgentActionsTests {
    private let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agentbar-actions-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func session(agent: String, entrypoint: String, state: String = "permission") throws -> Session {
        let url = dir.appendingPathComponent("\(UUID().uuidString).json")
        let o: [String: Any] = ["agent": agent, "state": state, "started": true,
                                "ts": 1_000, "project": "AgentBar", "label": "x",
                                "entrypoint": entrypoint, "pid": 4242]
        try JSONSerialization.data(withJSONObject: o).write(to: url)
        return try #require(Session(fileURL: url))
    }

    /// Codex is the awkward one: it has `approveKeys`, and it also has cloud tasks.
    /// A Return typed for a run on somebody else's machine lands in whatever window
    /// is in front of this one.
    @Test func aCloudRowIsNeverAimedAt() throws {
        #expect(AgentActions.mayKeystroke(try session(agent: "codex", entrypoint: "cloud")) == false)
        #expect(AgentActions.mayKeystroke(try session(agent: "devin", entrypoint: "cloud")) == false)
    }

    @Test func aLocalRowWithKeysStillIs() throws {
        #expect(AgentActions.mayKeystroke(try session(agent: "codex", entrypoint: "cli")))
        #expect(AgentActions.mayKeystroke(try session(agent: "copilot", entrypoint: "cli")))
    }

    /// An agent with no keys has nothing to type, whatever the row says.
    @Test func anAgentWithNoKeysIsNotAimedAtEither() throws {
        #expect(AgentActions.mayKeystroke(try session(agent: "claude", entrypoint: "cli")) == false)
        #expect(AgentActions.mayKeystroke(try session(agent: "cursor", entrypoint: "cli")) == false)
    }

    /// An agent AgentBar has never heard of used to resolve to Claude; now it
    /// resolves to a generic agent, and a generic agent carries no keys at all.
    /// Typing Return into a terminal whose prompt nobody here can read is exactly
    /// the keystroke this check exists to stop.
    @Test func anUnknownAgentIsNeverAimedAt() throws {
        let s = try session(agent: "aider", entrypoint: "cli")
        #expect(s.agent.approveKeys == nil)
        #expect(AgentActions.mayKeystroke(s) == false)
        // Not even when its id starts like an agent that does have keys.
        #expect(AgentActions.mayKeystroke(try session(agent: "codex-fork", entrypoint: "cli")) == false)
    }
}
