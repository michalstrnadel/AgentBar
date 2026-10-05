import Foundation
import Testing
@testable import AgentBar

/// `mods.d` beside `state.d`: read cheaply, kept through a torn write, merged onto
/// the right row, and tidied once nobody needs it — all in a borrowed home.
@Suite(.serialized) struct ModSidecarsTests {
    private let root: URL
    private var mods: URL { root.appendingPathComponent("mods.d", isDirectory: true) }
    private var state: URL { root.appendingPathComponent("state.d", isDirectory: true) }

    init() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-mods-\(UUID().uuidString)", isDirectory: true)
        root = AgentBarHome.root(home: home)
        try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }

    private var now: TimeInterval { Date().timeIntervalSince1970 }

    private func writeSidecar(_ id: String, ts: TimeInterval? = nil, ended: Bool = false,
                              percent: Int = 40, decisions: [String] = [],
                              mtime: Date? = nil) throws {
        let o: [String: Any] = [
            "v": 1, "agent": "claude", "session_id": id, "ts": ts ?? now, "ended": ended,
            "cwd": "/work/proj", "context": ["percent": percent], "subagents": 1,
            "rate_limits": [["kind": "five_hour", "percent_used": 10]],
            "decisions": decisions.map { ["id": $0, "ts": now - 1, "tool": "Bash",
                                          "input": ["command": "git status"],
                                          "verdict": "allow", "by": "mode"] },
        ]
        let url = mods.appendingPathComponent("\(id).json")
        try JSONSerialization.data(withJSONObject: o).write(to: url)
        if let mtime { try setMtime(url, mtime) }
    }

    private func setMtime(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func writeRow(_ id: String, project: String = "proj") throws {
        let o: [String: Any] = ["agent": "claude", "state": "thinking", "label": "Thinking…",
                                "project": project, "cwd": "/work/proj", "started": true,
                                "pid": 0, "ts": now]
        try JSONSerialization.data(withJSONObject: o).write(to: state.appendingPathComponent("\(id).json"))
    }

    private func exists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: mods.appendingPathComponent("\(id).json").path)
    }

    // MARK: - Reading

    @Test func aSidecarIsReadOnceAndAgainOnlyWhenItChanges() throws {
        let sidecars = ModSidecars(directory: mods)
        try writeSidecar("s1", percent: 40)
        let first = sidecars.refresh(sessionIDs: ["s1"])
        #expect(first.reports["s1"]?.context?.percent == 40)
        #expect(first.changed.map(\.sessionId) == ["s1"])
        // Nothing moved: nothing to hand on.
        let second = sidecars.refresh(sessionIDs: ["s1"])
        #expect(second.changed.isEmpty)
        #expect(second.reports["s1"]?.context?.percent == 40)
        try writeSidecar("s1", percent: 71, mtime: Date().addingTimeInterval(5))
        let third = sidecars.refresh(sessionIDs: ["s1"])
        #expect(third.changed.first?.context?.percent == 71)
    }

    /// The one file in the protocol that can be caught half-written: the last
    /// good report stands until the next whole one lands.
    @Test func aTornWriteKeepsTheLastGoodReport() throws {
        let sidecars = ModSidecars(directory: mods)
        try writeSidecar("s1", percent: 55)
        _ = sidecars.refresh(sessionIDs: ["s1"])
        let url = mods.appendingPathComponent("s1.json")
        try Data(#"{"v":1,"agent":"claude","session_id":"s1","ts":17"#.utf8).write(to: url)
        let torn = sidecars.refresh(sessionIDs: ["s1"])
        #expect(torn.reports["s1"]?.context?.percent == 55)
        #expect(torn.changed.isEmpty)
        try writeSidecar("s1", percent: 60, mtime: Date().addingTimeInterval(3))
        #expect(sidecars.refresh(sessionIDs: ["s1"]).reports["s1"]?.context?.percent == 60)
    }

    /// The permission hook's prompt marker goes with its session's row.
    @Test func aPromptMarkerGoesWithItsRow() throws {
        try Data("1".utf8).write(to: mods.appendingPathComponent(".prompted-s1"))
        try Data("1".utf8).write(to: mods.appendingPathComponent(".prompted-s2"))
        _ = ModSidecars(directory: mods).refresh(sessionIDs: ["s1"])
        #expect(FileManager.default.fileExists(atPath: mods.appendingPathComponent(".prompted-s1").path))
        #expect(!FileManager.default.fileExists(atPath: mods.appendingPathComponent(".prompted-s2").path))
    }

    @Test func ourOwnMemoryFileIsNotASidecar() throws {
        try Data(#"{"v":1,"sessions":{}}"#.utf8).write(to: mods.appendingPathComponent(".ingested.json"))
        let pass = ModSidecars(directory: mods).refresh(sessionIDs: [])
        #expect(pass.reports.isEmpty)
        #expect(FileManager.default.fileExists(atPath: mods.appendingPathComponent(".ingested.json").path))
    }

    // MARK: - Tidying up

    @Test func anEndedSessionsSidecarGoesWithItsRow() throws {
        let sidecars = ModSidecars(directory: mods)
        try writeSidecar("s1", ended: true)
        // The row is still there: the file stays, whatever it says.
        #expect(sidecars.refresh(sessionIDs: ["s1"]).pruned.isEmpty)
        #expect(exists("s1"))
        let gone = sidecars.refresh(sessionIDs: [])
        #expect(gone.pruned == ["s1"])
        #expect(!exists("s1"))
        #expect(gone.reports["s1"] == nil)
    }

    @Test func aQuietDayOldSidecarGoesOnceItsRowIsGone() throws {
        let sidecars = ModSidecars(directory: mods)
        try writeSidecar("old", ts: now - 90_000)
        try writeSidecar("fresh")
        try writeSidecar("kept", ts: now - 90_000)
        let pass = sidecars.refresh(sessionIDs: ["kept"])
        #expect(pass.pruned == ["old"])
        #expect(!exists("old"))
        #expect(exists("fresh"))     // not ended, not old: the row may not exist yet
        #expect(exists("kept"))      // its row is still on disk
    }

    @Test func junkThatNeverParsedGoesByItsOwnAge() throws {
        let url = mods.appendingPathComponent("junk.json")
        try Data("not json".utf8).write(to: url)
        try setMtime(url, Date().addingTimeInterval(-90_000))
        let pass = ModSidecars(directory: mods).refresh(sessionIDs: [])
        #expect(pass.pruned == ["junk"])
        #expect(!exists("junk"))
    }

    @Test func orphanRule() {
        let r = ModReport(sessionId: "s", ts: 1_000)
        #expect(!ModSidecars.isOrphan(r, fileMtime: 1_000, now: 1_000 + 3_600))
        #expect(ModSidecars.isOrphan(r, fileMtime: 1_000, now: 1_000 + 86_401))
        var ended = r
        ended.ended = true
        #expect(ModSidecars.isOrphan(ended, fileMtime: 1_000, now: 1_001))
        #expect(!ModSidecars.isOrphan(nil, fileMtime: 0, now: 1e9))
    }

    // MARK: - Onto the rows

    private func store(ledger: URL) -> SessionStore {
        SessionStore(stateDir: state, mods: ModSidecars(directory: mods),
                     liveQuota: ClaudeLiveQuota(refreshUsage: {}),
                     ingest: ClaudeDecisionIngest(ledgerURL: ledger,
                                                  storeURL: mods.appendingPathComponent(".ingested.json"),
                                                  isEnabled: { true }))
    }

    @Test func theStoreMergesTheModsFiguresOntoTheirRow() throws {
        try writeRow("s1")
        try writeRow("s2", project: "other")
        try writeSidecar("s1", percent: 82)
        let ledger = root.appendingPathComponent("decisions.jsonl")
        let s = store(ledger: ledger)
        var seen: [[Session]] = []
        s.onChange = { seen.append($0) }
        s.refresh()
        let rows = try #require(seen.last)
        let one = try #require(rows.first { $0.id == "s1" })
        #expect(one.modSeen)
        #expect(one.contextPercent == 82)
        #expect(one.subagents == 1)
        let two = try #require(rows.first { $0.id == "s2" })
        #expect(!two.modSeen)
        #expect(two.contextPercent == nil)

        // A context figure that moves is a visible change on its own.
        try writeSidecar("s1", percent: 91, mtime: Date().addingTimeInterval(4))
        s.refresh()
        #expect(seen.count == 2)
        #expect(seen.last?.first { $0.id == "s1" }?.contextPercent == 91)
        // And one that does not, is not.
        s.refresh()
        #expect(seen.count == 2)
    }

    @Test func theStoreHandsNewDecisionsToTheLedgerOnce() throws {
        try writeRow("s1", project: "proj")
        try writeSidecar("s1", decisions: ["toolu_a", "toolu_b"])
        let ledger = root.appendingPathComponent("decisions.jsonl")
        let ingest = ClaudeDecisionIngest(ledgerURL: ledger,
                                          storeURL: mods.appendingPathComponent(".ingested.json"),
                                          isEnabled: { true })
        let s = SessionStore(stateDir: state, mods: ModSidecars(directory: mods),
                             liveQuota: ClaudeLiveQuota(refreshUsage: {}), ingest: ingest)
        s.refresh()
        ingest.flush()
        try writeSidecar("s1", decisions: ["toolu_a", "toolu_b", "toolu_c"],
                         mtime: Date().addingTimeInterval(4))
        s.refresh()
        ingest.flush()
        let rows = DecisionLedger.read(url: ledger)
        #expect(rows.map(\.toolUseId) == ["toolu_a", "toolu_b", "toolu_c"])
        #expect(rows.allSatisfy { $0.via == "claude" && $0.project == "proj" && $0.waited == 0 })
    }

    /// A call a mod holds before it runs is a wait on the person: the working row
    /// becomes a waiting one that says what is held — and only while the row has
    /// not moved since the hold began.
    @Test func aHeldCallMakesTheRowWait() throws {
        try writeRow("s1")
        let row = try #require(Session(fileURL: state.appendingPathComponent("s1.json")))
        func report(since: TimeInterval) -> ModReport {
            var r = ModReport(sessionId: "s1", ts: now)
            r.held = .init(tool: "Bash", command: "rm -r build", since: since)
            return r
        }
        let held = try #require(SessionStore.merge(["s1": report(since: now + 2)], into: [row]).first)
        #expect(held.state == .permission)
        #expect(held.heldByMod)
        #expect(held.label == "Held before it runs: rm -r build")
        let moved = try #require(SessionStore.merge(["s1": report(since: now - 2)], into: [row]).first)
        #expect(moved.state == .thinking)
        #expect(!moved.heldByMod)
    }

    @Test func aRowWithoutTheModIsUntouched() throws {
        try writeRow("s1")
        let merged = SessionStore.merge([:], into: [try #require(Session(
            fileURL: state.appendingPathComponent("s1.json")))])
        #expect(merged.first?.modSeen == false)
    }
}
