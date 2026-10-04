import Cocoa

/// How full a session's context is, as a row says it: nothing at all until it is
/// worth knowing, then `ctx 82%`, amber when compaction is near and red when it is
/// imminent. Only Claude Code reports the figure, and only through the AgentBar mod
/// (`mods.d`), so a row without it says nothing rather than guessing.
///
/// Pure apart from the colours, so both surfaces — the island's chip and the menu
/// row's suffix — read the same thresholds and cannot disagree about them.
enum ContextGauge {
    enum Level: Equatable { case hidden, notice, high, critical }

    /// Below this the number is noise: every session has some context in use.
    static let showFrom = 70
    static let highFrom = 85
    static let criticalFrom = 95

    static func level(_ percent: Int?) -> Level {
        guard let p = percent, p >= showFrom else { return .hidden }
        if p >= criticalFrom { return .critical }
        if p >= highFrom { return .high }
        return .notice
    }

    /// "ctx 82%", or nil when the row should say nothing.
    static func text(_ percent: Int?) -> String? {
        guard let p = percent, level(p) != .hidden else { return nil }
        return "ctx \(p)%"
    }

    /// The words a screen reader gets for the same fact.
    static func spoken(_ percent: Int?) -> String? {
        guard let p = percent, level(p) != .hidden else { return nil }
        return "context \(p)% full"
    }

    /// The island's dark surface. `notice` is the same quiet white the model chip
    /// uses; the other two borrow the state dots' amber and red, so "context is
    /// running out" reads in the same colours as "look at this".
    static func islandTint(_ level: Level) -> NSColor {
        switch level {
        case .hidden, .notice: return NSColor.white.withAlphaComponent(0.85)
        case .high:            return IconRenderer.amberDot
        case .critical:        return NSColor(srgbRed: 1, green: 0.45, blue: 0.42, alpha: 1)
        }
    }

    /// The menu's system surface, where the text colours adapt to light and dark.
    static func menuColor(_ level: Level, fallback: NSColor) -> NSColor {
        switch level {
        case .hidden, .notice: return fallback
        case .high:            return .systemOrange
        case .critical:        return .systemRed
        }
    }
}
