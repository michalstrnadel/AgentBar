import Foundation

/// How much the repository moved while a session was open.
///
/// Read the name carefully, because the wording is the feature: this is **what
/// changed in the repo**, not what the agent did. You edit in the same working tree,
/// two sessions can share one checkout, and a build can drop files in. Nothing here
/// can separate those, and pretending otherwise would be the kind of number people
/// quote in a standup. So every string AgentBar shows says "changed", and the
/// measurement is bounded honestly: no baseline, no answer.
struct RepoChange: Equatable {
    var files = 0
    var added = 0
    var removed = 0
    /// Short sha the span was measured from, so a surprising row can be checked.
    var base = ""

    var isEmpty: Bool { files == 0 }

    var json: [String: Any] {
        ["files": files, "added": added, "removed": removed, "base": base]
    }

    init(files: Int = 0, added: Int = 0, removed: Int = 0, base: String = "") {
        self.files = files; self.added = added; self.removed = removed; self.base = base
    }

    init?(json: Any?) {
        guard let o = json as? [String: Any] else { return nil }
        files = (o["files"] as? NSNumber)?.intValue ?? 0
        added = (o["added"] as? NSNumber)?.intValue ?? 0
        removed = (o["removed"] as? NSNumber)?.intValue ?? 0
        base = o["base"] as? String ?? ""
    }
}

final class WorkDiff {
    static let shared = WorkDiff()

    /// One file's line counts. `binary` because `--numstat` prints `-` for a binary
    /// file rather than a number, and counting that as zero lines changed would make
    /// a replaced image look like no change at all.
    struct Stat: Equatable {
        var added = 0
        var removed = 0
        var binary = false
    }

    /// What the tree looked like when the session was first seen.
    struct Baseline: Equatable {
        let head: String
        /// Work already uncommitted at that moment. Subtracted at the end, so a
        /// session that opened on top of half-finished work is not credited with it.
        let dirt: [String: Stat]
    }

    private let lock = NSLock()
    /// sessionId → baseline, or `nil` recorded deliberately: the cwd is not a
    /// repository (or has no commits), and asking again every tick is wasted work.
    private var baselines: [String: Baseline?] = [:]
    /// When each id was last in the live set, so baselines for sessions that are long
    /// gone do not accumulate for as long as the app runs. Pruned generously late:
    /// the record that consumes a baseline is written asynchronously, *after* the
    /// session disappeared, and dropping it early would silently cost the numbers.
    private var lastSeen: [String: TimeInterval] = [:]
    private static let forgetAfter: TimeInterval = 600

    // MARK: - Wiring

    /// Called from the session fan-out. Takes a baseline the first time a session is
    /// seen and never again — the span is "since AgentBar first noticed you", which
    /// is why a session already running when the app launched gets no numbers at all.
    func observe(_ sessions: [Session]) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        for s in sessions { lastSeen[s.id] = now }
        for (id, at) in lastSeen where now - at > Self.forgetAfter {
            lastSeen.removeValue(forKey: id)
            baselines.removeValue(forKey: id)
        }
        lock.unlock()

        let fresh = sessions.filter { s in
            guard s.started, !s.cwd.isEmpty else { return false }
            lock.lock(); defer { lock.unlock() }
            return baselines.index(forKey: s.id) == nil
        }
        guard !fresh.isEmpty else { return }
        // Off the main queue: this shells out to git, and nothing on screen is
        // waiting for the answer.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for s in fresh {
                let baseline = Self.baseline(at: s.cwd)
                self.lock.lock()
                self.baselines[s.id] = baseline
                self.lock.unlock()
            }
        }
    }

    /// The span's change, or nil when it cannot be measured honestly. Blocking —
    /// `HistoryStore` calls it from its own serial queue.
    func change(sessionId: String, cwd: String) -> RepoChange? {
        lock.lock()
        let known = baselines[sessionId] ?? nil
        lock.unlock()
        guard let baseline = known, !cwd.isEmpty else { return nil }
        return Self.change(at: cwd, since: baseline)
    }


    // MARK: - git

    static func baseline(at cwd: String) -> Baseline? {
        guard let head = git(["rev-parse", "HEAD"], in: cwd)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty
        else { return nil }
        let dirt = git(["diff", "--numstat", "HEAD"], in: cwd).map(numstat) ?? [:]
        return Baseline(head: head, dirt: dirt)
    }

    static func change(at cwd: String, since baseline: Baseline) -> RepoChange? {
        // A reset, or a jump to an unrelated branch, makes the span meaningless: the
        // diff would describe the distance between two histories rather than a day's
        // work. Refuse rather than report it.
        guard git(["merge-base", "--is-ancestor", baseline.head, "HEAD"], in: cwd) != nil,
              let text = git(["diff", "--numstat", baseline.head], in: cwd)
        else { return nil }
        var out = delta(from: baseline.dirt, to: numstat(text))
        out.base = String(baseline.head.prefix(7))
        return out.isEmpty ? nil : out
    }

    /// `git diff --numstat` output → per-file counts. Format is
    /// `<added>\t<removed>\t<path>`, with `-` in both numeric columns for binaries.
    static func numstat(_ text: String) -> [String: Stat] {
        var out: [String: Stat] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let path = String(parts[2])
            if parts[0] == "-" || parts[1] == "-" {
                out[path] = Stat(binary: true)
            } else {
                out[path] = Stat(added: Int(parts[0]) ?? 0, removed: Int(parts[1]) ?? 0)
            }
        }
        return out
    }

    /// What the span added on top of what was already uncommitted when it began.
    ///
    /// Per file, and floored at zero: a session that *reverted* pre-existing edits
    /// produces a smaller diff than the baseline, and a negative line count is not a
    /// thing anyone can read. A file whose net is nothing is dropped entirely, so
    /// "7 files" means seven files that actually differ.
    ///
    /// It compares counts, not content, and that biases it **downwards**: rewriting
    /// eight already-uncommitted lines into eight different ones leaves the file's
    /// `+8/-0` unchanged and reports nothing. Exact when the tree was clean at the
    /// baseline, which is the ordinary case; never an overstatement otherwise, which
    /// is the side to err on for a number someone repeats.
    static func delta(from baseline: [String: Stat], to now: [String: Stat]) -> RepoChange {
        var out = RepoChange()
        for (path, stat) in now {
            let was = baseline[path]
            if stat.binary {
                // No line counts to compare, so the only honest question is whether
                // it was already dirty before the session started.
                if was == nil { out.files += 1 }
                continue
            }
            let added = max(0, stat.added - (was?.added ?? 0))
            let removed = max(0, stat.removed - (was?.removed ?? 0))
            guard added + removed > 0 else { continue }
            out.files += 1
            out.added += added
            out.removed += removed
        }
        return out
    }

    /// "7 files +210 −80" — the tail a history row carries. A true minus sign, not a
    /// hyphen, because it sits next to a plus.
    static func describe(_ c: RepoChange) -> String {
        var s = "\(c.files) file\(c.files == 1 ? "" : "s")"
        if c.added > 0 { s += " +\(c.added)" }
        if c.removed > 0 { s += " −\(c.removed)" }
        return s
    }

    // MARK: - Finding git without summoning a dialog

    /// Running `/usr/bin/git` on a Mac with no developer tools does not fail — it pops
    /// the "install the command line tools" dialog, which is exactly the kind of thing
    /// rule 2 says must never unfold over someone's screen because a background task
    /// felt like it. So the shim is only used once the tools it forwards to are known
    /// to be there, and a real git elsewhere is preferred.
    static let tool: String? = {
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        where fm.isExecutableFile(atPath: path) { return path }
        let installed = ["/Library/Developer/CommandLineTools/usr/bin/git",
                         "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        guard installed.contains(where: { fm.isExecutableFile(atPath: $0) }) else { return nil }
        return "/usr/bin/git"
    }()

    /// nil on any failure — a non-zero exit, a missing git, a directory that is not a
    /// repository. Callers turn that into "no numbers", never into zero.
    ///
    /// `Session.gitBranch` reads `.git/HEAD` by hand precisely so it never does this;
    /// it is a computed property evaluated for every row on every render, about once
    /// a second. This runs twice in a session's whole life, on a utility queue. The
    /// two are not in conflict, and neither should be "fixed" to match the other.
    @discardableResult
    static func git(_ args: [String], in cwd: String, timeout: TimeInterval = 8) -> String? {
        guard let tool else { return nil }
        return run(tool, args, in: cwd, timeout: timeout)
    }

    /// The runner itself, separate from git so the deadline can be tested with a
    /// child that is guaranteed to hang — which no git invocation reliably is.
    static func run(_ tool: String, _ args: [String], in cwd: String,
                    timeout: TimeInterval = 8) -> String? {
        guard FileManager.default.fileExists(atPath: cwd) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"     // never take index.lock for a read
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        // Drained on another thread, and killed at the deadline. The comment here
        // used to say a slow mount must not pin a queue forever, and then the code
        // did exactly that: `waitUntilExit` with nothing to end it. A repository on
        // a stalled network mount, or a `git` waiting on a lock somebody else holds,
        // took the utility queue with it — and a full pipe would deadlock the pair
        // before the wait even began.
        //
        // The reader gets a thread of its own rather than a global queue: a queue
        // hands it a worker only when one is free, and when every worker is blocked
        // — the caller's own queue among them — the reader never starts, and a
        // child that answered at once comes back as a timeout. CI caught that.
        var data = Data()
        let lock = NSLock()
        let done = DispatchSemaphore(value: 0)
        let reader = Thread {
            let read = out.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); data = read; lock.unlock()
            done.signal()
        }
        reader.qualityOfService = .utility
        reader.start()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 1)   // let the reader finish on the EOF
            return nil
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
