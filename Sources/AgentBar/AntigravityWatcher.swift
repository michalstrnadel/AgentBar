import Foundation

/// Liveness for Google Antigravity beyond its sparse hooks: the desktop engine
/// (2.3.x) fires only PostToolUse, so chat-only turns emit no hook events at
/// all. The per-conversation turn transcript under brain/<id>/ is appended to
/// only while the agent actually generates — a fresh mtime is the "working"
/// signal. (The conversation .db files are NOT usable for this: the app also
/// touches them during background housekeeping, which kept sessions "working"
/// forever.) The watcher upserts state files on the same ~/.agentbar/state.d
/// protocol the hooks use (hooks stay authoritative: a newer hook write wins),
/// and SessionStore's decay turns quiet sessions to done.
final class AntigravityWatcher {
    private let brainDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/antigravity/brain", isDirectory: true)
    private var timer: Timer?

    func start() {
        guard FileManager.default.fileExists(atPath: brainDir.path) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    private func scan() {
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970
        let dirs = (try? fm.contentsOfDirectory(at: brainDir, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let transcript = dir.appendingPathComponent(".system_generated/logs/transcript_full.jsonl")
            guard let mtime = (try? fm.attributesOfItem(atPath: transcript.path))?[.modificationDate]
                    as? Date, now - mtime.timeIntervalSince1970 < 10 else { continue }
            upsert(id: dir.lastPathComponent, ts: mtime.timeIntervalSince1970,
                   state: Self.turnFinished(transcript) ? "done" : "thinking")
        }
    }

    /// Transcript entries are appended complete, so a final MODEL …_RESPONSE with
    /// status DONE as the last line means the agent has answered — the turn is
    /// over the moment it lands, no need to wait for the decay timeout.
    private static func turnFinished(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size - min(size, 8192))
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8),
              let last = text.split(separator: "\n")
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let o = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any]
        else { return false }
        return o["source"] as? String == "MODEL"
            && o["status"] as? String == "DONE"
            && (o["type"] as? String ?? "").hasSuffix("RESPONSE")
    }

    private func upsert(id: String, ts: TimeInterval, state: String) {
        let safe = String(id.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }.prefix(64))
        guard !safe.isEmpty else { return }
        let url = SessionStore.stateDir.appendingPathComponent(safe + ".json")
        var o = ((try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        guard (o["agent"] as? String ?? "antigravity") == "antigravity" else { return }
        guard ts > (o["ts"] as? Double ?? 0) else { return } // a hook wrote something newer
        o["agent"] = "antigravity"
        o["state"] = state
        o["started"] = true
        o["ts"] = Int(ts)
        o["sessionId"] = safe
        // This watcher reads the desktop app's conversations dir only, so every
        // session it touches belongs to the app — row clicks must focus it, not
        // a terminal (an early bridge version misdetected "cli" here).
        o["entrypoint"] = "antigravity-app"
        o["term_program"] = ""
        guard let data = try? JSONSerialization.data(withJSONObject: o) else { return }
        try? FileManager.default.createDirectory(at: SessionStore.stateDir,
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
