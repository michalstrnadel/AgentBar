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
        /// Clawd: `frames` for the walk (frame 0 rests), plus a scene of
        /// `ClawdSceneArt` for each thing a session can be seen doing.
        case clawd([String], fps: Double)
        /// Single monochrome mark (base64 PNG), tinted with `brand`; animated as a bob.
        case tintedMark(String)
        /// Single full-color mark (base64 PNG); animated as a bob.
        case colorMark(String)
        /// Full-color app-icon-style mark on an opaque dark plate; templates as a
        /// knockout (plate becomes ink, bright artwork is cut out). Animated as a bob.
        case appIconMark(String)
        /// One letter knocked out of a filled rounded square, drawn rather than
        /// shipped: the mark of an agent AgentBar has never heard of, so a row
        /// written by any tool still gets a face that is its own and not Claude's.
        case monogram(Character)
    }

    enum OpenAction {
        case bundle(String)   // open by bundle identifier
        case appNamed(String) // open -a <name>
        case terminal         // bring the user's terminal forward
        case url(String)      // web-only agents: open their home in the browser
    }

    let id: String
    let name: String
    let brand: NSColor
    let artwork: Artwork
    let open: OpenAction
    /// Virtual key codes posted to approve a permission prompt in the agent's own UI.
    /// nil = no keystroke backend (Claude has the native hook path; Antigravity is an IDE).
    let approveKeys: [CGKeyCode]?

    /// The command that starts this agent in a terminal, if it has one. nil for the
    /// agents that only exist as an app or in somebody's cloud — the launcher does
    /// not offer those, because it could not start them.
    var cli: String?
    /// Whether that command takes the prompt as a plain argument.
    ///
    /// **Verified, not assumed** — each `true` here was read out of the tool's own
    /// `--help`. Copilot, OpenCode and Qwen document a prompt *flag* for their
    /// non-interactive modes, which is a different thing: guessing would start a
    /// session that runs once and exits with the work half done, so they open in
    /// the directory and wait for you to type.
    var takesPrompt = false

    static let all: [Agent] = [
        Agent(id: "claude", name: "Claude",
              brand: NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1), // #D97757
              artwork: .clawd(clawdCrabFramePNGs, fps: 12.5),
              open: .bundle("com.anthropic.claudefordesktop"),
              approveKeys: nil,
              cli: "claude", takesPrompt: true),        // claude [options] [prompt]
        Agent(id: "codex", name: "Codex",
              brand: NSColor(srgbRed: 0.063, green: 0.639, blue: 0.498, alpha: 1), // #10A37F
              artwork: .markFrames(codexMascotFramePNGs, fps: 11),
              open: .terminal,
              approveKeys: [36], // Return — Codex prompts default to approve
              cli: "codex", takesPrompt: true),         // codex [OPTIONS] [PROMPT]
        Agent(id: "copilot", name: "Copilot",
              brand: NSColor(srgbRed: 0.510, green: 0.314, blue: 0.875, alpha: 1), // #8250DF
              artwork: .frames(copilotMascotFramePNGs, fps: 11),
              open: .terminal,
              approveKeys: [16, 36], // "y" then Return
              cli: "copilot"),                          // -p is non-interactive only
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
              approveKeys: nil,
              cli: "cursor-agent", takesPrompt: true),  // agent [options] [prompt...]
        Agent(id: "gemini", name: "Gemini",
              brand: NSColor(srgbRed: 0.102, green: 0.502, blue: 0.992, alpha: 1), // #1A80FD — CLI icon blue
              artwork: .colorMark(geminiLogoPNG),
              open: .terminal,
              approveKeys: nil,
              cli: "gemini", takesPrompt: true),        // gemini [query..]
        // Hook-driven live status: Qwen Code speaks Claude-style hooks
        // (~/.qwen/settings.json), OpenCode loads a JS plugin.
        Agent(id: "qwen", name: "Qwen",
              brand: NSColor(srgbRed: 0.380, green: 0.361, blue: 0.929, alpha: 1), // #615CED
              artwork: .tintedMark(qwenMarkPNG),
              open: .terminal,
              approveKeys: nil,
              cli: "qwen"),                             // prompt argument unverified
        Agent(id: "opencode", name: "OpenCode",
              brand: .labelColor, // monochrome brand; adapt to menu appearance
              artwork: .appIconMark(opencodeMarkPNG),
              open: .terminal,
              approveKeys: nil,
              cli: "opencode"),                         // `run` is non-interactive only
        // Cloud-only: rows come from the external poller (Scripts/cloud), never hooks.
        Agent(id: "devin", name: "Devin",
              brand: NSColor(srgbRed: 0.169, green: 0.502, blue: 1.0, alpha: 1), // #2B80FF
              artwork: .tintedMark(devinMarkPNG),
              open: .url("https://app.devin.ai"),
              approveKeys: nil),
    ]

    /// The agent a row names. A known id is that agent; an empty id is Claude,
    /// the protocol's documented default for a file with no `agent` key (Claude
    /// Code's hooks predate the field). Anything else is an agent somebody wired
    /// up themselves, and it gets a generic entry of its own — it used to get
    /// `all[0]`, so an `aider` row wore the crab, said "Claude needs approval" and
    /// opened Claude Desktop when clicked.
    static func byID(_ id: String, name: String = "") -> Agent {
        if id.isEmpty { return all[0] }
        return all.first { $0.id == id } ?? generic(id: id, name: name)
    }

    /// An agent known only by the id a writer chose. Everything here is the
    /// least AgentBar can promise about a stranger: the terminal is where it
    /// probably runs, there is no command to launch it with, and above all
    /// `approveKeys` stays nil — posting Return into a terminal we know nothing
    /// about could approve something nobody read. Never added to `all`, so it
    /// cannot appear in the Open menu or the launcher.
    static func generic(id: String, name: String) -> Agent {
        let shown = name.isEmpty ? titleCased(id) : name
        let letter = shown.first(where: { $0.isLetter || $0.isNumber }).map { Character($0.uppercased()) } ?? "?"
        return Agent(id: id, name: shown.isEmpty ? id : shown,
                     brand: hue(for: id),
                     artwork: .monogram(letter),
                     open: .terminal,
                     approveKeys: nil,
                     cli: nil, takesPrompt: false)
    }

    /// "my-agent" → "My Agent".
    static func titleCased(_ id: String) -> String {
        id.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// A brand colour that is the same on every launch and every machine, so an
    /// agent keeps its colour from one day to the next. Swift's `hashValue` is
    /// seeded per process and would repaint it at every launch; FNV-1a over the
    /// id's UTF-8 bytes picks the hue instead. Saturation and brightness are held
    /// in the middle so the mark reads on a light menu bar and a dark island
    /// alike, and never shouts louder than the vendors' own colours beside it.
    static func hue(for id: String) -> NSColor {
        var h: UInt32 = 2_166_136_261
        for b in id.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return NSColor(hue: CGFloat(h % 360) / 360, saturation: 0.45,
               brightness: 0.72, alpha: 1)
    }
}
