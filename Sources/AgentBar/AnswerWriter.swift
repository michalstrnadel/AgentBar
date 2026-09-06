import Foundation

/// Writes the user's decision for a pending request; the blocking hook polls for it.
/// The answer file name must equal the request's so the hook finds its own answer.
enum AnswerWriter {
    /// behavior: "allow" | "always" | "deny" | "defer". The hook maps them to the
    /// PermissionRequest decision schema; "defer" means fall back to the terminal prompt.
    /// Returns false when the answer never reached disk — the hook keeps waiting,
    /// so the caller must leave the request actionable instead of clearing it.
    @discardableResult
    static func write(behavior: String, rule: [String: Any]? = nil, for request: ApprovalRequest) -> Bool {
        var obj: [String: Any] = ["behavior": behavior]
        if let rule { obj["rule"] = rule }
        return write(obj: obj, behavior: behavior, for: request)
    }

    /// A question's answer: the chosen option labels, one array per question. The
    /// hook only accepts labels the request itself offered, so there is nothing
    /// here a frontend could get creative with.
    @discardableResult
    static func writeAnswer(labels: [[String]], for request: ApprovalRequest) -> Bool {
        write(obj: ["behavior": "answer", "answers": labels], behavior: "answer", for: request)
    }

    private static func write(obj: [String: Any], behavior: String, for request: ApprovalRequest) -> Bool {
        var obj = obj
        // Name the hook this answer is meant for. Request file names repeat
        // across the tools of one turn, so a successor hook polling the same
        // name must be able to tell a predecessor's answer from its own — it
        // discards answers stamped with a pid that isn't its own.
        if request.hookPid > 0 { obj["hookPid"] = Int(request.hookPid) }
        let fm = FileManager.default
        let final = RequestStore.answersDir.appendingPathComponent(request.fileName)
        let data: Data
        do {
            try fm.createDirectory(at: RequestStore.answersDir, withIntermediateDirectories: true)
            data = try JSONSerialization.data(withJSONObject: obj)
        } catch {
            NSLog("AgentBar: answer '\(behavior)' not encodable for \(final.path): \(error)")
            return false
        }
        let tmp = RequestStore.answersDir.appendingPathComponent(
            request.fileName + ".\(ProcessInfo.processInfo.processIdentifier).tmp")
        do {
            try data.write(to: tmp)
            _ = try fm.replaceItemAt(final, withItemAt: tmp) // rename: atomic for the poller
            return true
        } catch {
            try? fm.removeItem(at: tmp)
            NSLog("AgentBar: answer '\(behavior)' not written to \(final.path): \(error)")
            return false
        }
    }
}
