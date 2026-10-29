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

extension AutoModeBlock {
    /// The hook keeps at most this many refusals on a row (`refused`).
    static let maxRefusals = 20

    /// Every call auto mode refused that the row still carries (`refused` in
    /// docs/protocol.md), as the verdicts they are: `deny`, decided by auto mode
    /// (`by: "auto"`) — the same decider the mod names when auto mode lets a call
    /// through, so one source in the history says both what it ran and what it
    /// refused. `ClaudeDecisionIngest` writes each to the ledger once, by its id.
    ///
    /// Checked the way `ModReport` checks a sidecar's decisions: the row is the
    /// hook's, the folder is anybody's. An entry without a usable id is dropped —
    /// it could not be counted only once.
    static func refusals(_ any: Any?, fallbackTs: TimeInterval) -> [ModReport.Decision] {
        guard let list = any as? [Any] else { return [] }
        var seen: Set<String> = []
        return list.suffix(maxRefusals).compactMap { item -> ModReport.Decision? in
            guard let o = item as? [String: Any],
                  let id = o["id"] as? String, !id.isEmpty, id.count <= 128,
                  !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0)
                                                        || CharacterSet.whitespaces.contains($0) }),
                  let tool = o["tool"] as? String, !tool.isEmpty,
                  seen.insert(id).inserted
            else { return nil }
            let stamp = Session.plausibleTime(o["ts"])
            var d = ModReport.Decision(id: id, ts: stamp > 0 ? stamp : fallbackTs,
                                       tool: ModReport.oneLine(tool, cap: 128),
                                       verdict: "deny", by: "auto")
            let input = o["input"] as? [String: Any] ?? [:]
            func field(_ k: String) -> String {
                guard let s = input[k] as? String else { return "" }
                return s.count > ModReport.maxField ? String(s.prefix(ModReport.maxField)) : s
            }
            d.command = field("command")
            d.filePath = field("file_path")
            d.url = field("url")
            d.reason = ModReport.oneLine(o["reason"] as? String ?? "", cap: ModReport.maxReason)
            return d
        }
    }
}
