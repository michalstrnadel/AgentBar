import Foundation

/// What auto mode's classifier refused this turn: the newest call, why, and how
/// many. Claude Code fires PermissionDenied for it and the model carries on, so a
/// working row would otherwise look as if nothing had happened (`blocked` in
/// docs/protocol.md). Only what the hook wrote; AgentBar answers none of it.
struct AutoModeBlock: Equatable {
    let tool: String
    let what: String
    let reason: String
    let count: Int

    init?(_ o: Any?) {
        guard let o = o as? [String: Any], let tool = o["tool"] as? String, !tool.isEmpty else { return nil }
        self.tool = String(tool.prefix(40))
        what = String((o["what"] as? String ?? "").prefix(80))
        reason = String((o["reason"] as? String ?? "").prefix(200))
        count = min(max((o["n"] as? NSNumber)?.intValue ?? 1, 1), 99)
    }

    /// "auto mode refused Bash · curl x | sh", or the count when it is not the first.
    var text: String {
        "auto mode refused \(tool) · " + (count > 1 ? "\(count) this turn" : what.isEmpty ? "this turn" : what)
    }

    /// The classifier's own words, for a tooltip.
    var detail: String {
        [count > 1 && !what.isEmpty ? "Last: \(tool) \(what)" : "", reason]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
