import Cocoa

/// Best-effort approval for agents without decision hooks (Codex, Copilot): bring
/// the session's terminal forward, then post the agent's approval keystroke.
/// Requires the Accessibility permission; the menu labels the action honestly
/// ("sends keystroke") because delivery to the right tab is not guaranteed.
/// We can at least guarantee the right *app*, and the right *key*: nothing is
/// posted unless the intended target is frontmost and no modifier is held, because
/// a stray Return lands in whatever the user was typing in, and a Return with ⌘
/// down is a different key. Every decision lives in `KeystrokeGate`; this is the
/// shell that asks the system and posts.
enum KeystrokeApprover {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system dialog directing the user to Privacy & Security ▸ Accessibility.
    static func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// `landedIn` is the app `TerminalFocus.focus` reported the session's own tab
    /// in front of — the caller has already brought that exact tab forward, so
    /// activating anything again would be redundant, and the frontmost wait below
    /// still guards the keys either way. It is passed rather than re-derived from
    /// TERM_PROGRAM because the two can differ: a session in a tmux pane reports
    /// "tmux", and the app that has to be in front before a key is posted is the
    /// terminal hosting the tmux client. Nil means nothing was aimed: bring the app
    /// TERM_PROGRAM names forward and wait for that.
    static func approve(session: Session, keys: [CGKeyCode], landedIn: String? = nil) {
        let target = KeystrokeGate.targetApp(entrypoint: session.entrypoint,
                                             termProgram: session.termProgram,
                                             landedIn: landedIn)
        if landedIn == nil {
            if session.entrypoint == "antigravity-app" {
                // Desktop Antigravity sessions live in the app, not a terminal.
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-a", target]
                do {
                    try p.run()
                } catch {
                    NSLog("AgentBar: could not launch \(target) for approval: \(error.localizedDescription)")
                    return
                }
            } else {
                AgentActions.focusTerminal(named: session.termProgram)
            }
        }
        send(keys, index: 0, to: target)
    }

    private static func isFront(_ target: String) -> Bool {
        let app = NSWorkspace.shared.frontmostApplication
        return KeystrokeGate.isTarget(target,
                                      localizedName: app?.localizedName,
                                      bundleName: app?.bundleURL?.deletingPathExtension().lastPathComponent)
    }

    /// The modifiers physically down right now, whatever any event says.
    private static var heldNow: CGEventFlags {
        CGEventSource.flagsState(.hidSystemState)
    }

    /// Polls the gate until it says send or give up. The frontmost app and the
    /// modifiers are read live on every look: either can change between keys.
    private static func whenClear(_ target: String, phase: KeystrokeGate.Phase, deadline: Date,
                                  then body: @escaping (Bool) -> Void) {
        switch KeystrokeGate.verdict(phase: phase, targetFront: isFront(target),
                                     held: heldNow, now: Date(), deadline: deadline) {
        case .send:
            body(true)
        case .giveUp(let why):
            NSLog("AgentBar: \(why) (\(target)); keystroke not sent")
            body(false)
        case .wait:
            DispatchQueue.main.asyncAfter(deadline: .now() + KeystrokeGate.pollInterval) {
                whenClear(target, phase: phase, deadline: deadline, then: body)
            }
        }
    }

    /// One key at a time, `keyStagger` apart, each behind its own look at the gate.
    private static func send(_ keys: [CGKeyCode], index: Int, to target: String) {
        guard index < keys.count else { return }
        whenClear(target, phase: index == 0 ? .activating : .midSequence,
                  deadline: KeystrokeGate.deadline(forKeyAt: index, from: Date())) { clear in
            guard clear else { return }
            post(keys[index])
            guard index + 1 < keys.count else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + KeystrokeGate.keyStagger) {
                send(keys, index: index + 1, to: target)
            }
        }
    }

    /// ⌘V into `target` once it is in front — the one key `DropToAgent` sends, and
    /// only into a tab `TerminalFocus` verified. Never a Return. `done(false)` when
    /// the app did not come forward or a modifier stayed held, so the caller can
    /// say ⌘V instead.
    static func paste(into target: String, done: @escaping (Bool) -> Void) {
        guard trusted else { return done(false) }
        whenClear(target, phase: .activating,
                  deadline: KeystrokeGate.deadline(forKeyAt: 0, from: Date())) { clear in
            if clear { post(9, flags: .maskCommand) }   // kVK_ANSI_V
            done(clear)
        }
    }

    /// Flags are set explicitly (`KeystrokeGate.events`): a modifier the user
    /// happens to be holding would otherwise ride along and turn Return into
    /// ⌘Return.
    private static func post(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for e in KeystrokeGate.events(for: key, flags: flags) {
            guard let event = CGEvent(keyboardEventSource: src, virtualKey: e.key, keyDown: e.keyDown)
            else { continue }
            event.flags = e.flags
            event.post(tap: .cghidEventTap)
        }
    }
}
