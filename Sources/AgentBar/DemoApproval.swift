import Foundation

/// "Try an approval": one made-up request, so somebody who has just installed
/// AgentBar can answer one before any agent is wired.
///
/// It is a request **only on screen**. It lives in memory, never in `requests.d`;
/// it reaches the surfaces through `merged(…)` and nothing else — not the
/// history, not the ledger, not the notifications, not a rule. Answering it writes
/// no file and runs nothing: `AgentActions` hands it here before any answer path.
/// It says it is a demo in its own words, and it goes away by itself after a few
/// minutes, the way a real one times out.
///
/// It opens nothing either. Started from a button the person pressed, it appears
/// the way a real request does — the pill says "approve?", and the pointer opens
/// the island — so the demo teaches the gesture rather than skipping it.
final class DemoApproval {
    static let shared = DemoApproval()

    static let sessionID = "agentbar-demo"
    static let lifetime: TimeInterval = 3 * 60

    /// Told whenever the demo appears or goes, so the surfaces redraw.
    var onChange: () -> Void = {}
    /// Told how it ended: "allow", "deny", "defer", or "expired".
    var onFinish: (String) -> Void = { _ in }

    private(set) var session: Session?
    private(set) var request: ApprovalRequest?
    private var expiry: DispatchWorkItem?

    var isActive: Bool { request != nil }

    static func isDemo(_ r: ApprovalRequest) -> Bool { r.sessionId == sessionID }
    static func isDemo(_ s: Session) -> Bool { s.id == sessionID }

    /// Puts the demo request up — once; a second press while it waits does nothing.
    func start(now: Date = Date()) {
        guard !isActive, let pair = Self.make(now: now) else { return }
        session = pair.session
        request = pair.request
        let work = DispatchWorkItem { [weak self] in self?.finish("expired") }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime, execute: work)
        onChange()
    }

    /// The person answered it (or it timed out). Nothing is written anywhere.
    func finish(_ behavior: String) {
        guard isActive else { return }
        expiry?.cancel()
        expiry = nil
        session = nil
        request = nil
        onChange()
        onFinish(behavior)
    }

    func merged(_ sessions: [Session]) -> [Session] {
        guard let session else { return sessions }
        return [session] + sessions.filter { !Self.isDemo($0) }
    }

    func merged(_ requests: [ApprovalRequest]) -> [ApprovalRequest] {
        guard let request else { return requests }
        return [request] + requests.filter { !Self.isDemo($0) }
    }

    /// The pair, built through the same decoders a real one goes through, so the
    /// card it gets is exactly the card a real request gets.
    static func make(now: Date = Date()) -> (session: Session, request: ApprovalRequest)? {
        let ts = Int(now.timeIntervalSince1970)
        let pid = ProcessInfo.processInfo.processIdentifier
        let dir = FileManager.default.temporaryDirectory
        let session: [String: Any] = [
            "agent": "claude", "state": "permission", "started": true, "ts": ts, "started_at": ts - 95,
            "project": "Try AgentBar", "cwd": "", "pid": Int(pid), "sessionId": sessionID,
            "label": "Bash", "prompt": "This is a demo — answering it runs nothing",
            "entrypoint": "demo",
        ]
        let request: [String: Any] = [
            "sessionId": sessionID, "agent": "claude", "toolName": "Bash",
            "display": "Bash: npm test", "toolInputPretty": "{\n  \"command\": \"npm test\"\n}",
            "context": ["kind": "bash", "command": "npm test",
                        "description": "Run the test suite (a demo — nothing will run)"],
            "pid": Int(pid), "hookPid": Int(pid), "ts": ts,
        ]
        // A session's id is its file's name, so the file is named for it — in a
        // directory of its own, read once and removed.
        func decode<T>(_ obj: [String: Any], _ make: (URL) -> T?) -> T? {
            let folder = dir.appendingPathComponent("agentbar-demo-\(UUID().uuidString)", isDirectory: true)
            let url = folder.appendingPathComponent(sessionID + ".json")
            defer { try? FileManager.default.removeItem(at: folder) }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  (try? data.write(to: url)) != nil else { return nil }
            return make(url)
        }
        guard let s = decode(session, { Session(fileURL: $0) }),
              let r = decode(request, { ApprovalRequest(fileURL: $0) }) else { return nil }
        return (s, r)
    }
}
