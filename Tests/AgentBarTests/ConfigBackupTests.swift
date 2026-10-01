import Foundation
import Testing
@testable import AgentBar

/// The copy AgentBar keeps before it writes into an agent's settings, and the diff
/// it records. The promises worth a test are the ones a person would only find
/// broken after they needed them: the original really is kept, a launch that
/// changes nothing leaves no trace, and rotation never takes a file that is not
/// AgentBar's own.
@Suite struct ConfigBackupTests {
    private let dir: URL
    private let log: URL

    init() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log = dir.appendingPathComponent("changes.json")
    }

    private func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.date(from: s)!
    }

    // MARK: - Names

    @Test func theNameSaysWhoseItIsAndWhen() {
        #expect(ConfigBackup.backupName(for: "settings.json", at: date("20261001-142233"))
                == "settings.json.agentbar-bak-20261001-142233")
    }

    /// Two writes inside one second: the earlier copy is the person's original, and
    /// it must not be the one overwritten.
    @Test func aSecondInTheSameSecondGetsACounter() {
        let first = "settings.json.agentbar-bak-20261001-142233"
        #expect(ConfigBackup.backupName(for: "settings.json", at: date("20261001-142233"),
                                        taken: [first]) == first + "-1")
        #expect(ConfigBackup.backupName(for: "settings.json", at: date("20261001-142233"),
                                        taken: [first, first + "-1"]) == first + "-2")
    }

    /// Rotation deletes, so what it counts as "ours" is the whole safety of it.
    @Test func onlyAgentBarsOwnBackupsOfThatFileCount() {
        let listing = [
            "settings.json",
            "settings.json.agentbar-bak-20261001-142233",
            "settings.json.agentbar-bak-mine",           // the person's own name
            "settings.json.bak",
            "settings.local.json.agentbar-bak-20261001-142233",  // another file's
        ]
        #expect(ConfigBackup.backups(of: "settings.json", among: listing)
                == ["settings.json.agentbar-bak-20261001-142233"])
    }

    @Test func rotationKeepsTheNewestAndOrdersCountersAsNumbers() {
        let b = "hooks.json.agentbar-bak-"
        let listing = [b + "20261001-120000", b + "20260930-120000", b + "20261001-120000-10",
                       b + "20261001-120000-9", b + "20261002-080000", "hooks.json"]
        #expect(ConfigBackup.expired(of: "hooks.json", among: listing, keep: 3)
                == [b + "20260930-120000", b + "20261001-120000"])
    }

    // MARK: - Writing

    @Test func theOriginalIsKeptBesideTheFile() throws {
        let url = dir.appendingPathComponent("settings.json")
        try Data("{\"theme\":\"dark\"}\n".utf8).write(to: url)
        let record = try ConfigBackup.write(Data("{\"hooks\":{}}\n".utf8), to: url,
                                            now: date("20261001-142233"), log: log)
        let backup = dir.appendingPathComponent("settings.json.agentbar-bak-20261001-142233")
        #expect(record?.backup == backup.path)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{\"theme\":\"dark\"}\n")
        #expect(try String(contentsOf: url, encoding: .utf8) == "{\"hooks\":{}}\n")
        #expect(record?.diff.contains("-{\"theme\":\"dark\"}") == true)
        #expect(record?.diff.contains("+{\"hooks\":{}}") == true)
        #expect(ConfigBackup.recent(log: log) == [record!])
    }

    /// A dotfiles setup: the settings file is a (relative) link into a repo. The
    /// write must land in the repo's file and leave the link a link; the backup sits
    /// next to the link, not in the repo, and keeps the target's permissions.
    @Test func aSymlinkedSettingsFileStaysALink() throws {
        let fm = FileManager.default
        let repo = dir.appendingPathComponent("dotfiles")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        let real = repo.appendingPathComponent("settings.json")
        try Data("{\"theme\":\"dark\"}\n".utf8).write(to: real)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        let link = dir.appendingPathComponent("settings.json")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "dotfiles/settings.json")

        let record = try ConfigBackup.write(Data("{\"hooks\":{}}\n".utf8), to: link,
                                            now: date("20261001-142233"), log: log)

        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == "dotfiles/settings.json")
        #expect(try String(contentsOf: real, encoding: .utf8) == "{\"hooks\":{}}\n")
        #expect((try fm.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int) == 0o600)
        let backup = dir.appendingPathComponent("settings.json.agentbar-bak-20261001-142233")
        #expect(record?.backup == backup.path)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{\"theme\":\"dark\"}\n")
        #expect((try fm.attributesOfItem(atPath: backup.path)[.type] as? FileAttributeType) == .typeRegular)
        #expect((try fm.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int) == 0o600)
        #expect(try fm.contentsOfDirectory(atPath: repo.path) == ["settings.json"])
    }

    /// The launch that finds everything already wired. Every launch is one, so any
    /// trace here would be a backup directory full of identical copies.
    @Test func aNoOpWritesNothingKeepsNothingRecordsNothing() throws {
        let url = dir.appendingPathComponent("settings.json")
        let same = Data("{\"hooks\":{}}\n".utf8)
        try same.write(to: url)
        let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(try ConfigBackup.write(same, to: url, log: log) == nil)
        #expect(names() == ["settings.json"])
        #expect(ConfigBackup.recent(log: log).isEmpty)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == mtime)
        #expect(ConfigBackup.preview(same, for: url) == nil)
    }

    @Test func aNewFileHasNoBackupButIsStillRecorded() throws {
        let url = dir.appendingPathComponent("agentbar.json")
        let record = try ConfigBackup.write(Data("{}\n".utf8), to: url, log: log)
        #expect(record?.backup == nil)
        #expect(record?.diff.hasPrefix("--- /dev/null\n+++ \(url.path)\n@@ -0,0 +1 @@\n+{}\n") == true)
        #expect(names() == ["agentbar.json", "changes.json"])
    }

    @Test func onlyTheLastFewBackupsStay() throws {
        let url = dir.appendingPathComponent("hooks.json")
        try Data("v0\n".utf8).write(to: url)
        try Data("theirs".utf8).write(to: dir.appendingPathComponent("hooks.json.agentbar-bak-mine"))
        for i in 1...5 {
            try ConfigBackup.write(Data("v\(i)\n".utf8), to: url,
                                   now: date("2026100\(i)-120000"), log: log, keep: 3)
        }
        #expect(names() == ["changes.json", "hooks.json",
                            "hooks.json.agentbar-bak-20261003-120000",
                            "hooks.json.agentbar-bak-20261004-120000",
                            "hooks.json.agentbar-bak-20261005-120000",
                            "hooks.json.agentbar-bak-mine"])
        // Each copy is the version that write replaced.
        #expect(try String(contentsOf: dir.appendingPathComponent("hooks.json.agentbar-bak-20261005-120000"),
                           encoding: .utf8) == "v4\n")
        #expect(ConfigBackup.recent(log: log).map(\.diff.isEmpty) == [false, false, false, false, false])
    }

    /// A preview is a question, not an answer: it must leave the disk alone.
    @Test func aPreviewTouchesNothing() throws {
        let url = dir.appendingPathComponent("settings.json")
        try Data("a\n".utf8).write(to: url)
        let record = ConfigBackup.preview(Data("b\n".utf8), for: url)
        #expect(record?.backup == nil)
        #expect(record?.diff.contains("-a\n+b\n") == true)
        #expect(names() == ["settings.json"])
        #expect(try String(contentsOf: url, encoding: .utf8) == "a\n")
    }

    // MARK: - The diff

    @Test func unifiedDiffNumbersItsHunksTheWayDiffDoes() {
        let old = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "line 5\n", with: "line five\n")
        let diff = LineDiff.unified(old: old, new: new, oldLabel: "a", newLabel: "b")
        #expect(diff == """
            --- a
            +++ b
            @@ -2,7 +2,7 @@
             line 2
             line 3
             line 4
            -line 5
            +line five
             line 6
             line 7
             line 8

            """)
    }

    @Test func twoDistantChangesAreTwoHunks() {
        let old = (1...20).map { "l\($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "l2\n", with: "L2\n")
                     .replacingOccurrences(of: "l19\n", with: "L19\n")
        let diff = LineDiff.unified(old: old, new: new, oldLabel: "a", newLabel: "b")
        #expect(diff.components(separatedBy: "\n@@ ").count - 1 == 2)
        #expect(diff.contains("@@ -1,5 +1,5 @@"))
        #expect(diff.contains("@@ -16,5 +16,5 @@"))
    }

    /// Codex's config gaining only a trailing newline is still a write, and a diff
    /// of it that came out empty would be a lie about a file that changed.
    @Test func aMissingFinalNewlineIsAChange() {
        let diff = LineDiff.unified(old: "model = \"o3\"", new: "model = \"o3\"\n",
                                    oldLabel: "a", newLabel: "b")
        #expect(diff.contains("-model = \"o3\"\n\\ No newline at end of file\n+model = \"o3\"\n"))
    }

    @Test func identicalTextsHaveNoDiff() {
        #expect(LineDiff.unified(old: "x\n", new: "x\n", oldLabel: "a", newLabel: "b").isEmpty)
    }

    /// A block appended to a long file costs a small table, not the file squared —
    /// and one too big for the table still comes out right, if plainer.
    @Test func aLargeFileIsDiffedFromItsChangedMiddle() {
        let old = (1...3000).map { "k\($0) = 1" }
        let new = old + ["# >>> agentbar >>>", "x = 1", "# <<< agentbar <<<"]
        let rows = LineDiff.alignLarge(old: old, new: new)
        #expect(rows.filter { $0.kind == .add }.count == 3)
        #expect(rows.filter { $0.kind == .same }.count == 3000)

        let fallback = LineDiff.alignLarge(old: ["a", "b", "c"], new: ["x", "b", "y"], maxCells: 1)
        #expect(fallback.map(\.kind) == [.del, .del, .del, .add, .add, .add])
    }

    // MARK: - The sheet's words

    @Test func pendingComesBeforeWhatWasWritten() {
        let r = ConfigBackup.Record(path: "/h/.claude/settings.json", backup: nil, ts: 0, diff: "")
        let entries = ConfigChangesSheet.entries(pending: [r], written: [r])
        #expect(entries == [.pending(r), .written(r)])
        #expect(ConfigChangesSheet.short("/h/.claude/settings.json", home: "/h") == "~/.claude/settings.json")
        #expect(ConfigChangesSheet.short("/hx/settings.json", home: "/h") == "/hx/settings.json")
    }
}
