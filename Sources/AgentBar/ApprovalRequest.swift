import Foundation

/// One pending permission request, decoded from `~/.agentbar/requests.d/*.json`
/// (written by the blocking permission hook while it waits for the user's answer).
struct ApprovalRequest {
    let fileName: String            // shared key: the answer file must use the same name
    let sessionId: String
    let agentID: String
    let toolName: String
    let display: String             // one line, e.g. "Bash: git push origin main"
    let toolInputPretty: String     // full tool input for the tooltip
    let ruleSuggestion: [String: Any]?  // Claude-supplied; passed back verbatim on Always allow
    let pid: Int32                  // the waiting hook's parent (the claude process)
    let hookPid: Int32              // the waiting hook itself; primary liveness handle
    let ts: TimeInterval

    init?(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        fileName        = fileURL.lastPathComponent
        sessionId       = o["sessionId"] as? String ?? ""
        agentID         = o["agent"] as? String ?? "claude"
        toolName        = o["toolName"] as? String ?? ""
        display         = o["display"] as? String ?? (o["toolName"] as? String ?? "request")
        toolInputPretty = o["toolInputPretty"] as? String ?? ""
        ruleSuggestion  = o["ruleSuggestion"] as? [String: Any]
        pid             = Int32(o["pid"] as? Int ?? 0)
        hookPid         = Int32(o["hookPid"] as? Int ?? 0)
        ts              = o["ts"] as? TimeInterval ?? 0
    }

    /// Text of the rule "Always allow" would persist — shown verbatim in the menu item.
    var ruleDescription: String? {
        guard let r = ruleSuggestion else { return nil }
        if let s = r["rule"] as? String { return s }
        guard let data = try? JSONSerialization.data(withJSONObject: r) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
