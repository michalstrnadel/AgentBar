import Cocoa

/// Everything AgentBar knows about one AI coding agent.
/// Adding an agent = one entry in `Agent.all` + a sprite + (optionally) hooks.
struct Agent {
    enum Artwork {
        /// Multi-frame full-color sprite sheet (base64 PNGs) played at `fps`.
        case frames([String], fps: Double)
        /// Like `frames`, but frame 0 is a resting-only mark (shown when the agent
        /// is idle/done) and the animation loops over frames 1…N while working.
        case markFrames([String], fps: Double)
        /// Single monochrome mark (base64 PNG), tinted with `brand`; animated as a bob.
        case tintedMark(String)
        /// Single full-color mark (base64 PNG); animated as a bob.
        case colorMark(String)
        /// Full-color app-icon-style mark on an opaque dark plate; templates as a
        /// knockout (plate becomes ink, bright artwork is cut out). Animated as a bob.
        case appIconMark(String)
    }

    enum OpenAction {
        case bundle(String)   // open by bundle identifier
        case appNamed(String) // open -a <name>
        case terminal         // bring the user's terminal forward
    }

    let id: String
    let name: String
    let brand: NSColor
    let artwork: Artwork
    let open: OpenAction
    /// Virtual key codes posted to approve a permission prompt in the agent's own UI.
    /// nil = no keystroke backend (Claude has the native hook path; Antigravity is an IDE).
    let approveKeys: [CGKeyCode]?

    static let all: [Agent] = [
        Agent(id: "claude", name: "Claude",
              brand: NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1), // #D97757
              artwork: .frames(clawdCrabFramePNGs, fps: 12.5),
              open: .bundle("com.anthropic.claudefordesktop"),
              approveKeys: nil),
        Agent(id: "codex", name: "Codex",
              brand: NSColor(srgbRed: 0.063, green: 0.639, blue: 0.498, alpha: 1), // #10A37F
              artwork: .markFrames(codexMascotFramePNGs, fps: 11),
              open: .terminal,
              approveKeys: [36]), // Return — Codex prompts default to approve
        Agent(id: "copilot", name: "Copilot",
              brand: NSColor(srgbRed: 0.510, green: 0.314, blue: 0.875, alpha: 1), // #8250DF
              artwork: .frames(copilotMascotFramePNGs, fps: 11),
              open: .terminal,
              approveKeys: [16, 36]), // "y" then Return
        Agent(id: "antigravity", name: "Antigravity",
              brand: NSColor(srgbRed: 0.259, green: 0.522, blue: 0.957, alpha: 1), // #4285F4
              artwork: .markFrames(antigravityMascotFramePNGs, fps: 11),
              open: .appNamed("Antigravity"),
              approveKeys: [36]), // Return — the approval dialog preselects "Yes, allow this time"
        // Hook-driven live status (Cursor: ~/.cursor/hooks.json; Gemini CLI: hooks).
        Agent(id: "cursor", name: "Cursor",
              brand: .labelColor, // Cursor's brand is monochrome; adapt to menu appearance
              artwork: .appIconMark(cursorLogoPNG),
              open: .terminal,
              approveKeys: nil),
        Agent(id: "gemini", name: "Gemini",
              brand: NSColor(srgbRed: 0.102, green: 0.502, blue: 0.992, alpha: 1), // #1A80FD — CLI icon blue
              artwork: .colorMark(geminiLogoPNG),
              open: .terminal,
              approveKeys: nil),
        // Hook-driven live status: Qwen Code speaks Claude-style hooks
        // (~/.qwen/settings.json), OpenCode loads a JS plugin.
        Agent(id: "qwen", name: "Qwen",
              brand: NSColor(srgbRed: 0.380, green: 0.361, blue: 0.929, alpha: 1), // #615CED
              artwork: .tintedMark(qwenMarkPNG),
              open: .terminal,
              approveKeys: nil),
        Agent(id: "opencode", name: "OpenCode",
              brand: .labelColor, // monochrome brand; adapt to menu appearance
              artwork: .appIconMark(opencodeMarkPNG),
              open: .terminal,
              approveKeys: nil),
    ]

    static func byID(_ id: String) -> Agent { all.first { $0.id == id } ?? all[0] }
}
