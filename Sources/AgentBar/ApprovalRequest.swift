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

    /// Text of the rule "Always allow" would persist — shown in the menu item.
    /// Claude Code suggestions come as {type:"addRules", rules:[{toolName, ruleContent}]};
    /// render those as "Bash(git push:*)" instead of raw JSON.
    var ruleDescription: String? {
        guard let r = ruleSuggestion else { return nil }
        if let s = r["rule"] as? String { return s }
        if let rules = r["rules"] as? [[String: Any]] {
            let parts = rules.compactMap { rule -> String? in
                guard let content = rule["ruleContent"] as? String else { return nil }
                let tool = rule["toolName"] as? String ?? ""
                return tool.isEmpty ? content : "\(tool)(\(content))"
            }
            if !parts.isEmpty { return parts.joined(separator: ", ") }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: r) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// ruleDescription cut to menu-title length; the full text belongs in a tooltip.
    var ruleMenuTitle: String? {
        guard let d = ruleDescription else { return nil }
        return d.count > 48 ? String(d.prefix(47)) + "…" : d
    }
}
