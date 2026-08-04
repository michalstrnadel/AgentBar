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
        let fm = FileManager.default
        let final = RequestStore.answersDir.appendingPathComponent(request.fileName)
        var obj: [String: Any] = ["behavior": behavior]
        if let rule { obj["rule"] = rule }
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
