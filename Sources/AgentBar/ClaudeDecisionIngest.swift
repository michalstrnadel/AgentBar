import Foundation

/// Turns what Claude Code decided without asking — the `decisions` ring of each
/// `mods.d` sidecar — into `decisions.jsonl` rows (`via: "claude"`), one per tool
/// call, ever (`docs/protocol.md`).
///
/// **One row per id, ever** is the whole difficulty, and it is answered twice. A
/// small file of its own, `mods.d/.ingested.json`, remembers per session which ids
/// of the ring were already taken; and the ledger's own `toolUseId`s are checked
/// too. Either alone has a way to forget — the ledger is emptied by
/// `agentbar forget` and pruned after 30 days, the small file can be deleted —
/// and a duplicate needs both to have forgotten at once. The per-session set is
/// the current ring and nothing more: an id that leaves the ring never comes back,
/// so the file stays as small as the sidecars it describes.
///
/// **What it writes depends on the same switch the person's own clicks do.** A
/// rule's firing is written regardless, because AgentBar answered and must be
/// accountable for it. Here AgentBar answered nothing — Claude Code did — and the
/// row carries a command line somebody may have typed a secret into, which is
/// exactly what *Remember what I decided* being off says not to keep. Ids seen
/// while it is off are still marked as taken, so turning it back on does not
/// backfill what happened while it was off.
///
/// Off the main queue, on a serial queue of its own: a ring is up to 200 entries
/// and the dedupe reads the ledger.
final class ClaudeDecisionIngest {
    static let shared = ClaudeDecisionIngest()

    static let defaultStore = AgentBarHome.url("mods.d/.ingested.json")

    private let ledgerURL: URL
    private let storeURL: URL
    private let isEnabled: () -> Bool
    private let queue = DispatchQueue(label: "agentbar.claude-ingest", qos: .utility)
    /// Session id → the ids of its ring already taken. Loaded on first use.
    private var taken: [String: Set<String>]?

    init(ledgerURL: URL = DecisionLedger.fileURL, storeURL: URL = ClaudeDecisionIngest.defaultStore,
         isEnabled: @escaping () -> Bool = { DecisionLedger.enabled }) {
        self.ledgerURL = ledgerURL
        self.storeURL = storeURL
        self.isEnabled = isEnabled
    }

    /// Reports whose content changed, with the project each session's row names.
    /// `onDisk` is every sidecar still in the folder: memory of the others goes.
    func ingest(_ reports: [ModReport], projects: [String: String], onDisk: Set<String>,
                now: TimeInterval = Date().timeIntervalSince1970) {
        guard !reports.isEmpty else { return }
        queue.async { [self] in
            var taken = self.taken ?? Self.load(storeURL)
            let before = taken
            let ledgerIDs = Set(DecisionLedger.cached(url: ledgerURL).lazy
                .filter { $0.via == "claude" && !$0.toolUseId.isEmpty }.map(\.toolUseId))
            var rows: [DecisionLedger.Record] = []
            for report in reports {
                let known = (taken[report.sessionId] ?? []).union(ledgerIDs)
                rows += Self.rows(for: report, project: projects[report.sessionId] ?? "",
                                  skipping: known, now: now)
                taken[report.sessionId] = Set(report.decisions.map(\.id))
            }
            for id in taken.keys where !onDisk.contains(id) { taken[id] = nil }
            if isEnabled(), !rows.isEmpty { DecisionLedger.append(rows, to: ledgerURL) }
            self.taken = taken
            if taken != before { Self.save(taken, to: storeURL) }
        }
    }

    func flush() { queue.sync {} }

    // MARK: - Pure

    /// The rows a report adds: every decision not already `skipping`, and young
    /// enough that the ledger would keep it — an older one would be written only
    /// to be pruned on the next launch, and then written again.
    static func rows(for report: ModReport, project: String, skipping known: Set<String>,
                     now: TimeInterval) -> [DecisionLedger.Record] {
        report.decisions.compactMap { d in
            guard !known.contains(d.id), now - d.ts <= DecisionLedger.maxAge else { return nil }
            var r = DecisionLedger.Record()
            r.ts = d.ts
            r.agent = "claude"
            r.sessionId = report.sessionId
            r.cwd = report.cwd
            r.project = project.isEmpty ? (report.cwd as NSString).lastPathComponent : project
            r.tool = d.tool
            r.shape = DecisionLedger.shape(tool: d.tool, input: input(of: d))
            r.display = display(d, cwd: report.cwd)
            r.decision = d.verdict
            r.waited = 0
            r.via = "claude"
            r.by = d.by
            r.claudeRule = d.rule
            r.reason = d.reason
            r.toolUseId = d.id
            return r
        }
    }

    static func input(of d: ModReport.Decision) -> [String: Any] {
        var o: [String: Any] = [:]
        if !d.command.isEmpty || d.tool == "Bash" { o["command"] = d.command }
        if !d.filePath.isEmpty { o["file_path"] = d.filePath }
        return o
    }

    /// The one-line summary the permission hook writes for the same call
    /// (`displaySummary` in `Scripts/hooks/claude/permission.js`), so a Claude Code
    /// row and a prompt about the same command read the same in the ledger.
    static func display(_ d: ModReport.Decision, cwd: String) -> String {
        let t = d.tool
        if t == "Bash" { return "Bash: " + oneLine(d.command) }
        if !d.filePath.isEmpty {
            var f = d.filePath
            if !cwd.isEmpty, f.hasPrefix(cwd + "/") { f = String(f.dropFirst(cwd.count + 1)) }
            return t + ": " + oneLine(f)
        }
        if !d.url.isEmpty { return t + ": " + oneLine(d.url) }
        if t.hasPrefix("mcp__") {
            let parts = t.dropFirst(5).components(separatedBy: "__")
            if parts.count >= 2, !parts[0].isEmpty {
                return parts[0] + ": " + parts.dropFirst().joined(separator: "__")
            }
        }
        if !d.description.isEmpty { return t + ": " + oneLine(d.description) }
        return t
    }

    /// First line, trimmed, cut at 60 with an ellipsis — the hook's `oneLine`.
    static func oneLine(_ s: String, _ n: Int = 60) -> String {
        let line = ModReport.oneLine(s, cap: Int.max)
        return line.count > n ? String(line.prefix(n - 1)) + "…" : line
    }

    // MARK: - The small file

    static func load(_ url: URL) -> [String: Set<String>] {
        guard let data = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (o["v"] as? Int) == 1,
              let sessions = o["sessions"] as? [String: Any]
        else { return [:] }
        var out: [String: Set<String>] = [:]
        for (id, ids) in sessions {
            if let list = ids as? [String] { out[id] = Set(list) }
        }
        return out
    }

    static func save(_ taken: [String: Set<String>], to url: URL) {
        let body: [String: Any] = ["v": 1, "sessions": taken.mapValues { $0.sorted() }]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Atomic: unlike the sidecars, this file is ours, and a torn copy of it
        // would be the one way to lose both memories at once.
        try? data.write(to: url, options: .atomic)
    }
}
