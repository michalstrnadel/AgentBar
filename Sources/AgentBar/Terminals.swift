import Cocoa

/// Known terminal apps: display name, bundle identifier, and the TERM_PROGRAM value
/// their sessions report (used to auto-pick a default from real usage).
struct TerminalApp {
    let name: String
    let bundleID: String
    let termProgram: String

    static let known: [TerminalApp] = [
        TerminalApp(name: "Terminal",  bundleID: "com.apple.Terminal",        termProgram: "Apple_Terminal"),
        TerminalApp(name: "iTerm",     bundleID: "com.googlecode.iterm2",     termProgram: "iTerm.app"),
        TerminalApp(name: "Warp",      bundleID: "dev.warp.Warp-Stable",      termProgram: "WarpTerminal"),
        TerminalApp(name: "Ghostty",   bundleID: "com.mitchellh.ghostty",     termProgram: "ghostty"),
        TerminalApp(name: "WezTerm",   bundleID: "com.github.wez.wezterm",    termProgram: "WezTerm"),
        TerminalApp(name: "kitty",     bundleID: "net.kovidgoyal.kitty",      termProgram: "kitty"),
        TerminalApp(name: "Alacritty", bundleID: "org.alacritty",             termProgram: "alacritty"),
    ]

    /// Terminals actually present on this Mac, in `known` order.
    static var installed: [TerminalApp] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    /// The terminal Open actions use. Explicit user choice wins; otherwise the terminal
    /// hosting the most recent CLI session; otherwise the first installed one.
    static func preferred(sessions: [Session]) -> TerminalApp {
        let d = UserDefaults.standard
        if let chosen = d.string(forKey: "preferredTerminal"),
           let hit = installed.first(where: { $0.bundleID == chosen }) {
            return hit
        }
        if let recent = sessions.max(by: { $0.ts < $1.ts })?.termProgram,
           let hit = installed.first(where: { $0.termProgram == recent }) {
            return hit
        }
        return installed.first ?? known[0]
    }

    static func setPreferred(_ terminal: TerminalApp) {
        UserDefaults.standard.set(terminal.bundleID, forKey: "preferredTerminal")
    }

    func open() {
        let ws = NSWorkspace.shared
        guard let url = ws.urlForApplication(withBundleIdentifier: bundleID) else { return }
        ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
