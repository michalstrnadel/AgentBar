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

    /// TERM_PROGRAM values map to app names almost verbatim; unknown values are used
    /// as-is (Ghostty, WezTerm, kitty, …). `KeystrokeApprover` needs the same answer to
    /// verify what came forward before it types, so the mapping lives here only.
    static func terminalAppName(for termProgram: String) -> String {
        switch termProgram {
        case "Apple_Terminal", "": return "Terminal"
        case "iTerm.app":          return "iTerm"
        case "vscode":             return "Visual Studio Code"
        case "WarpTerminal":       return "Warp"
        default:                   return termProgram
        }
    }

    /// Bring a terminal app to the front.
    static func focusTerminal(named termProgram: String) {
        openApp(named: terminalAppName(for: termProgram))
    }

    /// A row click: jump to wherever the session actually lives. A session waiting
    /// on us is released to its own prompt first, or the user lands on a spinner
    /// with the hook still blocked. (A question's wizard is already on screen, but
    /// deferring still retires the island card — answered where the user is going.)
    static func focus(_ s: Session, requests: [ApprovalRequest]) {
        if s.state == .permission || s.state == .question,
           let r = requests.first(where: { $0.sessionId == s.id }) {
            reportFailedAnswer(AnswerWriter.write(behavior: "defer", for: r))
        }
        switch s.entrypoint {
        case "claude-desktop":   open(Agent.byID("claude"))
        case "antigravity-app":  open(Agent.byID("antigravity"))
        default:                 TerminalFocus.focus(session: s)
        }
    }

    /// Allow / Always / Deny / defer from an inline button strip. False means the
    /// answer never reached disk: the request is still pending and still answerable.
    @discardableResult
    static func answer(_ a: ApprovalAction) -> Bool {
        // A plan cannot be approved through the hook — Claude Code ignores a
        // hook allow at the plan dialog (the approval also picks the next
        // permission mode). Approve by answering the dialog itself: focus the
        // session's exact tab and select "2. manually approve edits". The hook
        // notices the dialog was answered and retires the card on its own.
        if a.request.isPlanRequest, a.behavior == "allow" || a.behavior == "always" {
            // Typing "2" is only safe when the session's OWN tab is the one in
            // front. A desktop session keeps its dialog inside the Claude app,
            // and Warp/Ghostty/kitty expose no tab targeting — in both cases
            // hand over rather than type blind into whatever is frontmost.
            guard a.session.entrypoint != "claude-desktop",
                  TerminalFocus.canTargetTab(termProgram: a.session.termProgram) else {
                guard reportFailedAnswer(AnswerWriter.write(behavior: "defer", for: a.request))
                else { return false }
                if a.session.entrypoint == "claude-desktop" {
                    open(Agent.byID(a.session.agentID))
                } else {
                    TerminalFocus.focus(session: a.session)
                }
                return true
            }
            guard KeystrokeApprover.trusted else {
                KeystrokeApprover.requestAccess()
                return false
            }
            // Only after the tab select actually reports a hit: the app comes
            // forward in ~50ms while the AppleScript round-trip takes hundreds,
            // so posting the key straight away landed it in the wrong tab.
            TerminalFocus.focus(session: a.session) { targeted in
                guard targeted else {
                    // The tty didn't match any tab (session moved, tab closed):
                    // the user is already looking at the terminal — let them
                    // answer the dialog themselves rather than type into it.
                    reportFailedAnswer(AnswerWriter.write(behavior: "defer", for: a.request))
                    return
                }
                KeystrokeApprover.approve(session: a.session, keys: [19]) // "2"
            }
            return ack(true)
        }
        switch a.behavior {
        case "always":
            return ack(reportFailedAnswer(
                AnswerWriter.write(behavior: "always", rule: a.request.ruleSuggestion, for: a.request)))
        case "defer":
            // Hand off only once the hook can actually see the answer, or the user
            // arrives at a prompt that never reappears.
            guard reportFailedAnswer(AnswerWriter.write(behavior: "defer", for: a.request)) else { return false }
            // The prompt is about to reappear where the session lives: bring it
            // forward — the exact tab when the terminal can be asked for it.
            if a.session.entrypoint == "claude-desktop" {
                open(Agent.byID(a.session.agentID))
            } else {
                TerminalFocus.focus(session: a.session)
            }
            return true
        default:
            return ack(reportFailedAnswer(AnswerWriter.write(behavior: a.behavior, for: a.request)))
        }
    }

    /// Chosen option labels for a pending question, one array per question.
    /// False means the answer never reached disk — the card stays answerable.
    @discardableResult
    static func answerQuestion(_ labels: [[String]], request: ApprovalRequest) -> Bool {
        ack(reportFailedAnswer(AnswerWriter.writeAnswer(labels: labels, for: request)))
    }

    /// A dropped answer has no surface of its own — the row just stays pending — so
    /// the beep is the only cue that the click didn't land.
    @discardableResult
    static func reportFailedAnswer(_ written: Bool) -> Bool {
        if !written { NSSound.beep() }
        return written
    }

    /// The tiny confirm tick for a decision that actually reached disk. Defer is
    /// a hand-off, not a decision — it stays silent.
    @discardableResult
    static func ack(_ written: Bool) -> Bool {
        if written { SoundCenter.shared.playAck() }
        return written
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
                TerminalFocus.focus(session: session)
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
