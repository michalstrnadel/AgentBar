import Cocoa

/// Everything a session row can do, independent of the surface that hosts it.
/// The menu's `@objc` handlers and the island's button closures both land here,
/// so a click behaves identically wherever it came from.
enum AgentActions {
    /// The live session set. `TerminalApp.preferred` guesses which terminal a
    /// CLI agent should open into from the most recent session, so the actions
    /// need a view of it without owning a store.
    static var currentSessions: () -> [Session] = { [] }

    static func open(_ agent: Agent) {
        let ws = NSWorkspace.shared
        switch agent.open {
        case .bundle(let id):
            if let url = ws.urlForApplication(withBundleIdentifier: id) {
                ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else {
                TerminalApp.preferred(sessions: currentSessions()).open()
            }
        case .appNamed(let name):
            openApp(named: name)
        case .terminal:
            // CLI-only agents open into the user's terminal (chosen in Open ▸ Terminal,
            // or auto-detected from the most recent session).
            TerminalApp.preferred(sessions: currentSessions()).open()
        }
    }

    /// Bring a terminal app to the front. TERM_PROGRAM values map to app names almost
    /// verbatim; unknown values are tried as-is (Ghostty, WezTerm, kitty, …).
    static func focusTerminal(named termProgram: String) {
        let app: String
        switch termProgram {
        case "Apple_Terminal", "": app = "Terminal"
        case "iTerm.app":          app = "iTerm"
        case "vscode":             app = "Visual Studio Code"
        case "WarpTerminal":       app = "Warp"
        default:                   app = termProgram
        }
        openApp(named: app)
    }

    /// A row click: jump to wherever the session actually lives. A session waiting
    /// on us is released to its own prompt first, or the user lands on a spinner
    /// with the hook still blocked.
    static func focus(_ s: Session, requests: [ApprovalRequest]) {
        if s.state == .permission, let r = requests.first(where: { $0.sessionId == s.id }) {
            AnswerWriter.write(behavior: "defer", for: r)
        }
        switch s.entrypoint {
        case "claude-desktop":   open(Agent.byID("claude"))
        case "antigravity-app":  open(Agent.byID("antigravity"))
        default:                 focusTerminal(named: s.termProgram)
        }
    }

    /// Allow / Always / Deny / defer from an inline button strip.
    static func answer(_ a: ApprovalAction) {
        switch a.behavior {
        case "always":
            AnswerWriter.write(behavior: "always", rule: a.request.ruleSuggestion, for: a.request)
        case "defer":
            AnswerWriter.write(behavior: "defer", for: a.request)
            // The prompt is about to reappear where the session lives: bring it forward.
            if a.session.entrypoint == "claude-desktop" {
                open(Agent.byID(a.session.agentID))
            } else {
                focusTerminal(named: a.session.termProgram)
            }
        default:
            AnswerWriter.write(behavior: a.behavior, for: a.request)
        }
    }

    /// Inline strip on keystroke-backed permission rows (Antigravity, Codex, Copilot).
    static func keystroke(_ behavior: String, session: Session) {
        switch behavior {
        case "allow":
            guard let keys = Agent.byID(session.agentID).approveKeys else { return }
            if KeystrokeApprover.trusted {
                KeystrokeApprover.approve(session: session, keys: keys)
            } else {
                KeystrokeApprover.requestAccess()
            }
        case "grant":
            KeystrokeApprover.requestAccess()
        default: // "open" — jump to the prompt and answer there
            if session.entrypoint == "antigravity-app" {
                open(Agent.byID(session.agentID))
            } else {
                focusTerminal(named: session.termProgram)
            }
        }
    }

    private static func openApp(named name: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", name]
        try? p.run()
    }
}
