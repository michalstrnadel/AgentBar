import Foundation
import Testing
@testable import AgentBar

/// The arithmetic behind "7 files +210 −80". Everything here is the pure part: no
/// repository is created and `git` is never run, because what can go wrong is the
/// subtraction, not the shelling out.
@Suite struct WorkDiffTests {
    private func stats(_ pairs: [(String, Int, Int)]) -> [String: WorkDiff.Stat] {
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, WorkDiff.Stat(added: $0.1, removed: $0.2)) })
    }

    // MARK: - Parsing

    @Test func numstatIsReadPerFile() {
        let out = WorkDiff.numstat("10\t2\tSources/A.swift\n0\t5\tREADME.md\n")
        #expect(out["Sources/A.swift"] == WorkDiff.Stat(added: 10, removed: 2))
        #expect(out["README.md"] == WorkDiff.Stat(added: 0, removed: 5))
    }

    /// `--numstat` prints `-` in both numeric columns for a binary file. Reading that
    /// as zero would make a replaced image look like nothing happened.
    @Test func aBinaryFileIsAFileWithNoLines() {
        let out = WorkDiff.numstat("-\t-\tSources/Sprites/clawd.png\n")
        #expect(out["Sources/Sprites/clawd.png"]?.binary == true)
        let change = WorkDiff.delta(from: [:], to: out)
        #expect(change.files == 1)
        #expect(change.added == 0)
        #expect(change.removed == 0)
    }

    /// Paths with tabs are not a thing git emits unquoted, but a path with spaces is,
    /// and splitting on the wrong number of fields would silently drop it.
    @Test func aPathWithSpacesSurvives() {
        let out = WorkDiff.numstat("3\t1\tMacbook M3/Warp/A File.swift\n")
        #expect(out["Macbook M3/Warp/A File.swift"] == WorkDiff.Stat(added: 3, removed: 1))
    }

    // MARK: - The subtraction

    /// The whole point. Work already uncommitted when the session opened is not the
    /// session's work, and crediting it is how a number becomes a lie.
    @Test func workAlreadyThereWhenTheSessionStartedIsNotCounted() {
        let before = stats([("A.swift", 100, 0)])
        let after = stats([("A.swift", 130, 10), ("B.swift", 5, 0)])
        let change = WorkDiff.delta(from: before, to: after)
        #expect(change.files == 2)
        #expect(change.added == 35)   // 30 on A, 5 on B
        #expect(change.removed == 10)
    }

    /// A session that reverted pre-existing edits leaves a smaller diff than the
    /// baseline. "−20 lines added" is not a thing anyone can read.
    @Test func undoingEarlierWorkFloorsAtZeroRatherThanGoingNegative() {
        let change = WorkDiff.delta(from: stats([("A.swift", 100, 50)]),
                                    to: stats([("A.swift", 10, 5)]))
        #expect(change == RepoChange())
    }

    /// "7 files" has to mean seven files that actually differ.
    @Test func aFileThatEndedWhereItStartedIsNotCounted() {
        let same = stats([("A.swift", 12, 3)])
        #expect(WorkDiff.delta(from: same, to: same).files == 0)
    }

    @Test func aCleanTreeThatStayedCleanIsNoChangeAtAll() {
        #expect(WorkDiff.delta(from: [:], to: [:]).isEmpty)
    }

    /// A binary that was already modified before the session cannot be attributed
    /// either way — there are no line counts to compare — so it is left alone.
    @Test func aBinaryThatWasAlreadyDirtyIsNotClaimed() {
        let binary = WorkDiff.numstat("-\t-\ticon.png\n")
        #expect(WorkDiff.delta(from: binary, to: binary).files == 0)
    }

    // MARK: - Wording

    @Test(arguments: [(RepoChange(files: 1, added: 3, removed: 0), "1 file +3"),
                      (RepoChange(files: 7, added: 210, removed: 80), "7 files +210 −80"),
                      (RepoChange(files: 2), "2 files")])
    func theTailReadsTheWayARowNeedsIt(_ change: RepoChange, _ want: String) {
        #expect(WorkDiff.describe(change) == want)
    }

    // MARK: - Refusing

    /// A session AgentBar was not running for has no baseline, and inventing one from
    /// "whatever is uncommitted right now" would report a week of work as a morning's.
    @Test func noBaselineMeansNoNumbers() {
        #expect(WorkDiff.shared.change(sessionId: "never-seen", cwd: "/tmp") == nil)
    }

    @Test func anEmptyCwdIsNotAskedAbout() {
        #expect(WorkDiff.shared.change(sessionId: "x", cwd: "") == nil)
    }

    /// Not a repository — the overwhelmingly common case for a session started in a
    /// home directory or a scratch folder.
    @Test func somewhereThatIsNotARepositoryHasNoBaseline() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-norepo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        #expect(WorkDiff.baseline(at: tmp.path) == nil)
    }

    // MARK: - The record

    @Test func changeRoundTripsThroughJSON() throws {
        let change = RepoChange(files: 7, added: 210, removed: 80, base: "3a30264")
        let back = try #require(RepoChange(json: change.json))
        #expect(back == change)
    }

    @Test func absentIsNotZero() {
        #expect(RepoChange(json: nil) == nil)
        #expect(RepoChange(json: "not an object") == nil)
    }
    /// The runner used to promise in a comment that a slow repository "must not pin
    /// a queue forever" and then called `waitUntilExit` with nothing to end it. A
    /// child that never returns has to come back as no answer, not as a hung queue.
    /// Tested with `sleep` rather than a git command, because no git invocation
    /// hangs reliably enough to be a test.
    @Test func aChildThatNeverReturnsGivesUp() throws {
        let started = Date()
        let result = WorkDiff.run("/bin/sleep", ["30"], in: NSTemporaryDirectory(), timeout: 1)
        #expect(result == nil)
        #expect(Date().timeIntervalSince(started) < 5)   // gave up, did not hang
    }

    /// And the ordinary path still returns what the child wrote.
    @Test func aChildThatAnswersIsRead() throws {
        let out = try #require(WorkDiff.run("/bin/echo", ["hello"], in: NSTemporaryDirectory()))
        #expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    /// The reader must not wait for a free worker thread. CI caught it: with the
    /// suite's other tests blocking threads in parallel, a reader queued on a
    /// global queue sat behind them, and `echo` came back as a timeout. Here the
    /// utility queue is filled with work that blocks until the child has answered.
    @Test func aChildIsReadEvenWhenEveryWorkerIsBusy() throws {
        let release = DispatchSemaphore(value: 0)
        let blockers = 256
        for _ in 0..<blockers {
            DispatchQueue.global(qos: .utility).async { release.wait() }
        }
        defer { for _ in 0..<blockers { release.signal() } }
        let out = WorkDiff.run("/bin/echo", ["hello"], in: NSTemporaryDirectory(), timeout: 3)
        #expect(out?.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

}
