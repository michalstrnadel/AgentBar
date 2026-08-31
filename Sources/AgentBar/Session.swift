import Foundation

/// One live agent session, decoded from a `~/.agentbar/state.d/*.json` file
/// written by the hook scripts in `Scripts/hooks/`.
struct Session {
    enum State: String {
        case idle, thinking, tool, permission, question, done, error

        var isWorking: Bool { self == .thinking || self == .tool }
        /// The turn is over either way; only `done` earned the celebration.
        var isFinished: Bool { self == .done || self == .error || self == .idle }
    }

    let id: String
    let agentID: String
    var state: State
    /// True when `state` was synthesized by a frontend watchdog (Antigravity's
    /// 90s quiet decay), not reported by the agent — celebrations should skip it.
    var decayed = false
    let label: String
    let project: String
    let cwd: String
    let entrypoint: String   // "cli", "claude-desktop", …
    let termProgram: String  // TERM_PROGRAM of the hosting terminal, for row clicks
    let pid: Int32           // the agent process; used for liveness pruning
    let started: Bool        // false until the session has real activity
    let ts: TimeInterval
    let startedAt: TimeInterval // 0 = the writer doesn't carry the field
    let prompt: String       // latest user prompt — names the task ("" ok)
    let model: String        // model name when the agent reports one ("" ok)
    let recap: String        // what the agent last said at turn end ("" ok)
    let activity: [String]   // the turn's recent tool steps, oldest → newest ([] ok)

    /// Sort/priority weight: what the menu bar should surface first.
    var priority: Int {
        switch state {
        case .permission:      return 4
        case .question:        return 3
        case .thinking, .tool: return 2
        // Above the clean finishes so a failure can't be buried under them, but
        // below live work: an errored session must never take the hero slot (or
        // the mascot) from an agent that is still going.
        case .error:           return 1
        case .idle, .done:     return 0
        }
    }

    init?(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        id          = fileURL.deletingPathExtension().lastPathComponent
        agentID     = o["agent"] as? String ?? "claude"
        state       = State(rawValue: o["state"] as? String ?? "") ?? .idle
        label       = o["label"] as? String ?? ""
        project     = o["project"] as? String ?? ""
        cwd         = o["cwd"] as? String ?? ""
        entrypoint  = o["entrypoint"] as? String ?? ""
        termProgram = o["term_program"] as? String ?? ""
        // Third-party writers reach state.d too (the protocol invites them): an
        // out-of-range or negative pid must degrade to "no liveness handle",
        // never trap — the poisoned file survives on disk, so a trap here is a
        // crash loop that outlives every relaunch.
        pid         = max(0, Int32(exactly: o["pid"] as? Int ?? 0) ?? 0)
        started     = o["started"] as? Bool ?? true
        ts          = o["ts"] as? TimeInterval ?? 0
        startedAt   = o["started_at"] as? TimeInterval ?? 0
        prompt      = o["prompt"] as? String ?? ""
        model       = o["model"] as? String ?? ""
        recap       = o["recap"] as? String ?? ""
        activity    = (o["activity"] as? [String] ?? []).prefix(5).map { String($0.prefix(40)) }
    }

    /// "‹1m" / "28m" / "3h" / "2d" — how long the session has been going.
    /// Nil until a writer carries `started_at`, so old files render unchanged.
    var elapsed: String? {
        guard startedAt > 0 else { return nil }
        let s = Int(Date().timeIntervalSince1970 - startedAt)
        guard s >= 0 else { return nil }
        if s < 60 { return "<1m" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    /// The model, stripped of brand noise a chip has no room for:
    /// "claude-opus-5" → "opus-5". Nil when unknown.
    var modelChip: String? {
        guard !model.isEmpty else { return nil }
        var m = model.lowercased()
        for prefix in ["claude-", "anthropic/", "openai/", "google/"] where m.hasPrefix(prefix) {
            m.removeFirst(prefix.count)
        }
        return String(m.prefix(16))
    }

    /// Synthetic row for the welcome window's live preview. Never written by a
    /// hook and never reaches the stores — it exists so the preview animates the
    /// real mascot through the real driver instead of faking a picture.
    init(preview state: State, agentID: String = "claude", project: String, label: String) {
        id = "preview"
        self.agentID = agentID
        self.state = state
        self.label = label
        self.project = project
        cwd = ""
        entrypoint = ""
        termProgram = ""
        pid = 0
        started = true
        ts = Date().timeIntervalSince1970
        startedAt = 0
        prompt = ""
        model = ""
        recap = ""
        activity = []
        decayed = false
    }

    /// Current git branch of the session's project, read straight from `.git/HEAD`
    /// (no `git` invocation; handles worktrees via the `gitdir:` indirection).
    var gitBranch: String? {
        guard !cwd.isEmpty else { return nil }
        var gitPath = cwd + "/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue { // worktree: .git is a file containing "gitdir: <path>"
            guard let s = try? String(contentsOfFile: gitPath, encoding: .utf8),
                  let dir = s.split(separator: ":").dropFirst().joined(separator: ":")
                    .trimmingCharacters(in: .whitespacesAndNewlines) as String?
            else { return nil }
            gitPath = dir
        }
        guard let head = try? String(contentsOfFile: gitPath + "/HEAD", encoding: .utf8) else { return nil }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref: refs/heads/") {
            return String(line.dropFirst("ref: refs/heads/".count))
        }
        return String(line.prefix(7)) // detached HEAD: short SHA
    }
}
