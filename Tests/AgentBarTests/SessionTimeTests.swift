import Foundation
import Testing
@testable import AgentBar

/// `state.d` is written by anybody the protocol invites — hooks, the cloud poller,
/// rows mirrored from another machine — and a time outside Int's range traps the
/// first `Int(_:)` it meets. These pin that such a time never gets that far.
@Suite struct SessionTimeTests {
    @Test func anAbsurdTimeIsNoTime() {
        #expect(Session.plausibleTime(1e300) == 0)
        #expect(Session.plausibleTime(-1e300) == 0)
        #expect(Session.plausibleTime(Double.infinity) == 0)
        #expect(Session.plausibleTime(Double.nan) == 0)
        #expect(Session.plausibleTime("1789000000") == 0)
        #expect(Session.plausibleTime(nil) == 0)
    }

    @Test func anOrdinaryTimeSurvives() {
        #expect(Session.plausibleTime(1_789_000_000) == 1_789_000_000)
        #expect(Session.plausibleTime(NSNumber(value: 1_789_000_000.5)) == 1_789_000_000.5)
    }

    @Test func aRowWithAnAbsurdStartStillDecodesAndDoesNotTrap() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-time-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Int(Date().timeIntervalSince1970)
        try Data(#"{"agent":"claude","state":"error","sessionId":"x","pid":1,"started":true,"ts":\#(now),"started_at":1e300}"#.utf8)
            .write(to: url)
        let s = try #require(Session(fileURL: url))
        #expect(s.startedAt == 0)
        #expect(s.elapsed == nil)
    }

    /// A submodule's `.git` is a file whose `gitdir:` is relative to the directory
    /// holding it. Read as given, it named nothing and the branch went missing.
    @Test func aRelativeGitdirIsReadFromTheDirectoryHoldingIt() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-git-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let modules = root.appendingPathComponent(".git/modules/sub")
        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: modules, withIntermediateDirectories: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("ref: refs/heads/feature/x\n".utf8).write(to: modules.appendingPathComponent("HEAD"))
        try Data("gitdir: ../.git/modules/sub\n".utf8).write(to: sub.appendingPathComponent(".git"))

        let row = root.appendingPathComponent("row.json")
        let o: [String: Any] = ["agent": "claude", "state": "thinking", "sessionId": "x",
                                "pid": 1, "cwd": sub.path,
                                "ts": Date().timeIntervalSince1970]
        try JSONSerialization.data(withJSONObject: o).write(to: row)
        let s = try #require(Session(fileURL: row))
        #expect(s.gitBranch == "feature/x")
    }
}
