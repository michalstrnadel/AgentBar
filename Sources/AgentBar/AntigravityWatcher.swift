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
                    as? Date else { continue }
            let ts = mtime.timeIntervalSince1970
            let age = now - ts
            if age < 10 {
                // Live turn. A final MODEL …_RESPONSE without tool_calls means the
                // agent has answered — flip to done immediately, no decay wait.
                let last = Self.lastEntry(transcript)
                upsert(id: dir.lastPathComponent, ts: ts,
                       state: Self.isFinalResponse(last) ? "done" : "thinking")
            } else if age < 900 {
                // Quiet with an unexecuted tool request as the last entry: the app
                // is sitting on its own approval prompt (auto-allowed tools append
                // their result within moments).
                if let tool = Self.pendingToolCall(Self.lastEntry(transcript)) {
                    upsert(id: dir.lastPathComponent, ts: ts, state: "permission", label: tool)
                }
            }
        }
    }

    private static func lastEntry(_ url: URL) -> [String: Any]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size - min(size, 8192))
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8),
              let last = text.split(separator: "\n")
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Any]
    }

    private static func isFinalResponse(_ o: [String: Any]?) -> Bool {
        guard let o else { return false }
        return o["source"] as? String == "MODEL"
            && o["status"] as? String == "DONE"
            && (o["type"] as? String ?? "").hasSuffix("RESPONSE")
            && o["tool_calls"] == nil
    }

    private static func pendingToolCall(_ o: [String: Any]?) -> String? {
        guard let o, o["source"] as? String == "MODEL",
              let calls = o["tool_calls"] as? [[String: Any]], let first = calls.first
        else { return nil }
        return first["name"] as? String ?? "tool"
    }

    private func upsert(id: String, ts: TimeInterval, state: String, label: String? = nil) {
        let safe = String(id.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }.prefix(64))
        guard !safe.isEmpty else { return }
        let url = SessionStore.stateDir.appendingPathComponent(safe + ".json")
        var o = ((try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        guard (o["agent"] as? String ?? "antigravity") == "antigravity" else { return }
        // A hook write with a newer ts is authoritative; a same-ts state change
        // (thinking → permission after the quiet threshold) must still land.
        let prevTs = o["ts"] as? Double ?? 0
        guard ts > prevTs || (ts >= prevTs && state != (o["state"] as? String)) else { return }
        o["agent"] = "antigravity"
        o["state"] = state
        o["started"] = true
        if let label { o["label"] = label }
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
