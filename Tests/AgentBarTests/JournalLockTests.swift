import Foundation
import Testing
@testable import AgentBar

/// The lock the app and the Linux CLI share around `history.jsonl` and
/// `decisions.jsonl` (docs/protocol.md, "Locking the journals"). The CLI's half is
/// held to the same contract by `Scripts/test/cli-test.sh`.
@Suite(.serialized) struct JournalLockTests {
    private let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agentbar-journal-lock-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Another open file description stands in for the CLI: a flock conflicts across
    /// descriptions even inside one process.
    private func holdSidecar(of journal: URL) -> Int32 {
        let fd = open(JournalLock.sidecar(for: journal).path, O_RDWR | O_CREAT, 0o644)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        return fd
    }

    @Test func theSidecarSitsBesideTheJournal() {
        let journal = dir.appendingPathComponent("decisions.jsonl")
        #expect(JournalLock.sidecar(for: journal).path == journal.path + ".lock")
    }

    @Test func aHolderElsewhereMakesItBusyAndLettingGoMakesItHeld() {
        let journal = dir.appendingPathComponent("history.jsonl")
        let fd = holdSidecar(of: journal)
        let started = Date()
        #expect(JournalLock.around(journal, inProcess: NSLock(), wait: 0.2) { $0 } == .busy)
        // Bounded: nothing in the app may hang on a CLI stopped while holding it.
        #expect(Date().timeIntervalSince(started) < 1.5)
        close(fd)
        #expect(JournalLock.around(journal, inProcess: NSLock(), wait: 0.2) { $0 } == .held)
    }

    /// The app's own prune and append really take the cross-process lock: while
    /// somebody else holds it, a prune waits rather than rewriting underneath them.
    @Test func aPruneWaitsForTheOtherWriter() throws {
        let url = dir.appendingPathComponent("decisions.jsonl")
        let now = Date().timeIntervalSince1970
        var old = DecisionLedger.Record()
        old.shape = "bash:ls"; old.decision = "allow"; old.ts = now - 40 * 86_400
        DecisionLedger.append([old], to: url)
        let fd = holdSidecar(of: url)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { DecisionLedger.prune(url: url, now: now); done.signal() }
        #expect(done.wait(timeout: .now() + 0.3) == .timedOut)
        #expect(DecisionLedger.read(url: url).count == 1)  // not pruned under the holder
        close(fd)
        #expect(done.wait(timeout: .now() + 3) == .success)
        #expect(DecisionLedger.read(url: url).isEmpty)
    }

    /// The issue this lock exists for (#28): the real CLI appending decisions while
    /// the app prunes the same ledger over and over. Every CLI row must survive.
    @Test func cliAppendsInterleavedWithAppPrunesLoseNothing() throws {
        let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/cli/agentbar")
        guard FileManager.default.fileExists(atPath: cli.path) else { return }
        let home = dir.appendingPathComponent("agentbar")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("requests.d"),
                                                withIntermediateDirectories: true)
        let ledger = home.appendingPathComponent("decisions.jsonl")
        let rounds = 25
        let script = """
        command -v node >/dev/null 2>&1 || exit 77
        for i in $(seq 1 \(rounds)); do
          printf '{"sessionId":"s1","agent":"claude","toolName":"Bash","display":"Bash: ls","toolInputPretty":"{}","pid":%s,"hookPid":%s,"ts":%s}' \
            $$ $$ "$(date +%s)" > "$AGENTBAR_HOME/requests.d/r$i.json"
          node "$CLI" approve >/dev/null 2>&1 || exit 1
        done
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        var env = ProcessInfo.processInfo.environment
        env["AGENTBAR_HOME"] = home.path
        env["CLI"] = cli.path
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        try p.run()

        // The app's side: a row old enough to age out, then a prune that has to
        // rewrite the file to drop it — read, write a copy, rename — as fast as it can.
        var prunes = 0
        while p.isRunning {
            let now = Date().timeIntervalSince1970
            var old = DecisionLedger.Record()
            old.shape = "bash:ls"; old.decision = "allow"; old.ts = now - 40 * 86_400
            DecisionLedger.append([old], to: ledger)
            DecisionLedger.prune(url: ledger, now: now)
            prunes += 1
        }
        p.waitUntilExit()
        if p.terminationStatus == 77 { return }  // no node on this machine
        #expect(p.terminationStatus == 0)
        #expect(prunes > 0)
        let cliRows = DecisionLedger.read(url: ledger).filter { $0.via == "cli" }
        #expect(cliRows.count == rounds)
    }
}
