import Foundation

/// Writes the user's decision for a pending request; the blocking hook polls for it.
/// The answer file name must equal the request's so the hook finds its own answer.
enum AnswerWriter {
    /// behavior: "allow" | "always" | "deny" | "defer". The hook maps them to the
    /// PermissionRequest decision schema; "defer" means fall back to the terminal prompt.
    static func write(behavior: String, rule: [String: Any]? = nil, for request: ApprovalRequest) {
        let fm = FileManager.default
        try? fm.createDirectory(at: RequestStore.answersDir, withIntermediateDirectories: true)
        var obj: [String: Any] = ["behavior": behavior]
        if let rule { obj["rule"] = rule }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let final = RequestStore.answersDir.appendingPathComponent(request.fileName)
        let tmp = RequestStore.answersDir.appendingPathComponent(
            request.fileName + ".\(ProcessInfo.processInfo.processIdentifier).tmp")
        do {
            try data.write(to: tmp)
            _ = try fm.replaceItemAt(final, withItemAt: tmp) // rename: atomic for the poller
        } catch {
            try? fm.removeItem(at: tmp)
        }
    }
}
