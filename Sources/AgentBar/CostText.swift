import Foundation

/// What a session has cost, as the island and the menu say it. Claude Code prices
/// every turn, on a subscription too, so the figure is "what this would cost at
/// API prices", and the tooltip says so rather than the chip.
enum CostText {
    /// "$0.42", "$12", "<$0.01" — nil when unknown or nothing yet.
    static func short(_ usd: Double?) -> String? {
        guard let usd, usd > 0 else { return nil }
        if usd < 0.01 { return "<$0.01" }
        if usd < 10 { return String(format: "$%.2f", usd) }
        return String(format: "$%.0f", usd.rounded())
    }

    static let note = "What this session has cost so far at API prices, as Claude Code counts it. On a subscription it is not what you are billed."
}

/// One subagent at work, in a line: "Explore · list files · haiku · 2m".
enum SubagentLine {
    static func text(_ a: ModReport.Subagent, now: TimeInterval) -> String {
        var parts = [a.type]
        if !a.what.isEmpty { parts.append(a.what) }
        if let m = shortModel(a.model) { parts.append(m) }
        if a.since > 0 {
            let m = Int(max(0, now - a.since) / 60)
            parts.append(m < 1 ? "<1m" : "\(m)m")
        }
        if a.background { parts.append("background") }
        return parts.joined(separator: " · ")
    }

    /// "claude-haiku-5-5" → "haiku"; anything else as it came.
    static func shortModel(_ id: String) -> String? {
        guard !id.isEmpty else { return nil }
        for family in ["fable", "opus", "sonnet", "haiku"] where id.lowercased().contains(family) { return family }
        return id
    }
}
