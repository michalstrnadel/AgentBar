import Cocoa

/// Everything AgentBar knows about one AI coding agent.
/// Adding an agent = one entry in `Agent.all` + a sprite + (optionally) hooks.
struct Agent {
    enum Artwork {
        /// Multi-frame full-color sprite sheet (base64 PNGs) played at `fps`.
        case frames([String], fps: Double)
        /// Single monochrome mark (base64 PNG), tinted with `brand`; animated as a bob.
        case tintedMark(String)
        /// Single full-color mark (base64 PNG); animated as a bob.
        case colorMark(String)
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
              artwork: .frames(codexMascotFramePNGs, fps: 11),
              open: .terminal,
              approveKeys: [36]), // Return — Codex prompts default to approve
        Agent(id: "copilot", name: "Copilot",
              brand: NSColor(srgbRed: 0.510, green: 0.314, blue: 0.875, alpha: 1), // #8250DF
              artwork: .frames(copilotMascotFramePNGs, fps: 11),
              open: .terminal,
              approveKeys: [16, 36]), // "y" then Return
        Agent(id: "antigravity", name: "Antigravity",
              brand: NSColor(srgbRed: 0.259, green: 0.522, blue: 0.957, alpha: 1), // #4285F4
              artwork: .frames(antigravityMascotFramePNGs, fps: 11),
              open: .appNamed("Antigravity"),
              approveKeys: nil),
    ]

    static func byID(_ id: String) -> Agent { all.first { $0.id == id } ?? all[0] }
}
