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
        case .url(let s):
            if let url = URL(string: s) { ws.open(url) }
        }
    }

    /// Bring a terminal app to the front by the name its TERM_PROGRAM gives —
    /// the floor under every row click. The mapping itself is
    /// `TerminalApp.appName(forTermProgram:)`, shared with `KeystrokeApprover`.
    static func focusTerminal(named termProgram: String) {
        openApp(named: TerminalApp.appName(forTermProgram: termProgram))
    }

    /// Any state file in `~/.agentbar/state.d` can name a `url`, and the protocol
    /// deliberately invites third-party writers — so a row click must not become
    /// "open whatever handler this scheme names". A list of what may open, not of
    /// what may not: the web, and the vendors whose cloud rows link into their app.
    /// A denylist was always one scheme short (`x-man-page`, `applescript`, `vnc`…).
    static let openableURLSchemes: Set<String> = ["https", "http", "ssh", "cursor", "devin", "codex", "vscode"]

    static func openableCloudURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        return openableURLSchemes.contains(scheme)
    }

    /// A row click: jump to wherever the session actually lives. A session waiting
    /// on us is released to its own prompt first, or the user lands on a spinner
    /// with the hook still blocked. (A question's wizard is already on screen, but
    /// deferring still retires the island card — answered where the user is going.)
    static func focus(_ s: Session, requests: [ApprovalRequest]) {
        // A cloud session lives at a URL, not in anything local: open it and stop —
        // there is no tty to resolve and no blocked hook to release. Checked first
        // so no local-only path can ever run for a row the poller wrote.
        if s.entrypoint == "cloud" {
            if let url = URL(string: s.url), openableCloudURL(url) {
                NSWorkspace.shared.open(url)
            } else {
                NSSound.beep() // no url, or one we refuse to open — nowhere to go
            }
            return
        }
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
                    open(a.session.agent)
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
            TerminalFocus.focus(session: a.session) { landedIn in
                guard let landedIn else {
                    // The tty didn't match any tab (session moved, tab closed):
                    // the user is already looking at the terminal — let them
                    // answer the dialog themselves rather than type into it.
                    reportFailedAnswer(AnswerWriter.write(behavior: "defer", for: a.request))
                    return
                }
                KeystrokeApprover.approve(session: a.session, keys: [19], landedIn: landedIn) // "2"
            }
            return ack(true)
        }
        switch a.behavior {
        case "always":
            return ack(remember("always", a, reportFailedAnswer(
                AnswerWriter.write(behavior: "always", rule: a.request.ruleSuggestion, for: a.request))))
        case "defer":
            // Hand off only once the hook can actually see the answer, or the user
            // arrives at a prompt that never reappears.
            guard remember("defer", a, reportFailedAnswer(
                AnswerWriter.write(behavior: "defer", for: a.request))) else { return false }
            // The prompt is about to reappear where the session lives: bring it
            // forward — the exact tab when the terminal can be asked for it.
            if a.session.entrypoint == "claude-desktop" {
                open(a.session.agent)
            } else {
                TerminalFocus.focus(session: a.session)
            }
            return true
        default:
            return ack(remember(a.behavior, a,
                                reportFailedAnswer(AnswerWriter.write(behavior: a.behavior,
                                                                      message: a.note,
                                                                      for: a.request))))
        }
    }

    /// Writes the decision to the ledger, but **only once it actually reached
    /// disk** — a click that failed is not something you did, and counting it would
    /// make "allowed 23× here" include prompts that went on to time out in the
    /// terminal. Passes the written flag straight through so it can wrap a call.
    ///
    /// The plan branch above is deliberately not on this path: approving a plan is
    /// a keystroke into a terminal, and nothing here learns what the terminal made
    /// of it. See `DecisionLedger`.
    @discardableResult
    private static func remember(_ decision: String, _ a: ApprovalAction, _ written: Bool) -> Bool {
        if written {
            DecisionLedger.shared.record(decision, request: a.request, session: a.session)
        }
        return written
    }

    /// Chosen option labels for a pending question, one array per question.
    /// False means the answer never reached disk — the card stays answerable.
    @discardableResult
    static func answerQuestion(_ labels: [[String]], request: ApprovalRequest) -> Bool {
        let written = reportFailedAnswer(AnswerWriter.writeAnswer(labels: labels, for: request))
        if written {
            // A question has no session in hand here, and it needs none: what the
            // day wants from it is how long the agent waited for an answer.
            DecisionLedger.shared.record("answer", request: request,
                                         session: currentSessions().first { $0.id == request.sessionId })
        }
        return ack(written)
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

    /// Whether a keystroke may be aimed at this session at all.
    ///
    /// A keystroke lands in a terminal **on this machine**. A row carrying
    /// `entrypoint: "cloud"` describes a run on somebody else's, so there is no tab
    /// to aim at and the keys would go to whatever window happens to be in front —
    /// with `approveKeys` that is a Return typed into a stranger's prompt. `focus`
    /// has always checked this first; the inline strip did not, and `docs/protocol.md`
    /// lets **anybody** write a row, so the poller's own discipline is not the place
    /// to rely on.
    static func mayKeystroke(_ session: Session) -> Bool {
        session.entrypoint != "cloud" && session.agent.approveKeys != nil
    }

    /// Inline strip on keystroke-backed permission rows (Antigravity, Codex, Copilot).
    static func keystroke(_ behavior: String, session: Session) {
        switch behavior {
        case "allow":
            guard mayKeystroke(session),
                  let keys = session.agent.approveKeys else { return }
            guard KeystrokeApprover.trusted else {
                KeystrokeApprover.requestAccess()
                return
            }
            // Same discipline the plan approval follows: when the terminal can be
            // aimed at a single tab, wait for the tty match before typing. Bringing
            // the app forward takes ~50ms and the AppleScript round-trip hundreds,
            // so keys posted straight away land in whichever tab was already open.
            // A desktop Antigravity session has no tab to aim, and Warp/Ghostty/kitty
            // expose none — those keep the app-level path, which is what the menu's
            // "sends keystroke" has always promised.
            guard session.entrypoint != "antigravity-app",
                  TerminalFocus.canTargetTab(termProgram: session.termProgram) else {
                KeystrokeApprover.approve(session: session, keys: keys)
                return
            }
            TerminalFocus.focus(session: session) { landedIn in
                guard let landedIn else {
                    // The tty matched no tab — the session moved or its tab is
                    // gone. The terminal is already in front; let the user answer
                    // the prompt rather than type into a stranger's tab.
                    NSLog("AgentBar: session tab not found; approval keystroke not sent")
                    return
                }
                KeystrokeApprover.approve(session: session, keys: keys, landedIn: landedIn)
            }
        case "grant":
            KeystrokeApprover.requestAccess()
        default: // "open" — jump to the prompt and answer there
            if session.entrypoint == "antigravity-app" {
                open(session.agent)
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
