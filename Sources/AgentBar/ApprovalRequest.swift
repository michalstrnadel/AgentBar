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
    let context: Context?           // structured detail for the inline mini-diff / command
    let pid: Int32                  // the waiting hook's parent (the claude process)
    let hookPid: Int32              // the waiting hook itself; primary liveness handle
    let ts: TimeInterval

    /// What's being approved, in enough detail to render inline without the terminal.
    enum Context {
        case bash(String)                              // full command
        case diff(old: String, new: String, more: Int) // Edit/MultiEdit (more = extra edits)
        case write(String)                             // Write content preview
        case question([Question])                      // AskUserQuestion — answerable in place
        case plan(String)                              // ExitPlanMode — the plan markdown

        /// One AskUserQuestion entry, options included, so a frontend can offer
        /// the same choices the terminal wizard does.
        struct Question {
            let question: String
            let header: String
            let options: [(label: String, description: String)]
            let multiSelect: Bool
        }
    }

    /// The decoded questions when this request is an answerable AskUserQuestion.
    var questions: [Context.Question]? {
        if case .question(let qs) = context { return qs }
        return nil
    }

    /// A plan review has its own answer semantics (a hook allow can't approve
    /// it), so the check keys on the tool — a plan whose text failed to decode
    /// must not degrade into a generic Allow/Deny card that lies about Allow.
    var isPlanRequest: Bool { toolName == "ExitPlanMode" }

    /// The plan markdown when this request is an ExitPlanMode review.
    var planText: String? {
        if case .plan(let text) = context { return text }
        return nil
    }

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
        context         = Self.decodeContext(o["context"] as? [String: Any])
        pid             = Int32(o["pid"] as? Int ?? 0)
        hookPid         = Int32(o["hookPid"] as? Int ?? 0)
        ts              = o["ts"] as? TimeInterval ?? 0
    }

    private static func decodeContext(_ c: [String: Any]?) -> Context? {
        guard let c, let kind = c["kind"] as? String else { return nil }
        switch kind {
        case "bash":  return .bash(c["command"] as? String ?? "")
        case "diff":  return .diff(old: c["old"] as? String ?? "",
                                   new: c["new"] as? String ?? "",
                                   more: c["more"] as? Int ?? 0)
        case "write": return .write(c["preview"] as? String ?? "")
        case "question":
            let qs = (c["questions"] as? [[String: Any]] ?? []).map { q in
                Context.Question(
                    question: q["question"] as? String ?? "",
                    header: q["header"] as? String ?? "",
                    options: (q["options"] as? [[String: Any]] ?? []).map {
                        (label: $0["label"] as? String ?? "",
                         description: $0["description"] as? String ?? "")
                    }.filter { !$0.label.isEmpty },
                    multiSelect: q["multiSelect"] as? Bool ?? false)
            }.filter { !$0.question.isEmpty && !$0.options.isEmpty }
            return qs.isEmpty ? nil : .question(qs)
        case "plan":
            let text = c["plan"] as? String ?? ""
            return text.isEmpty ? nil : .plan(text)
        default:      return nil
        }
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
