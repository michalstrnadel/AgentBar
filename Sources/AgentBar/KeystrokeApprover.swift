import Cocoa

/// Best-effort approval for agents without decision hooks (Codex, Copilot): bring
/// the session's terminal forward, then post the agent's approval keystroke.
/// Requires the Accessibility permission; the menu labels the action honestly
/// ("sends keystroke") because delivery to the right tab is not guaranteed.
/// We can at least guarantee the right *app*: nothing is posted unless the
/// intended target is frontmost, because a stray Return lands in whatever the
/// user was typing in.
enum KeystrokeApprover {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// How long to wait for the target to come forward, and how often to look.
    /// Cold-start launches are slow; a missed approval beats an early keystroke.
    private static let activationDeadline: TimeInterval = 2.0
    private static let pollInterval: TimeInterval = 0.05
    /// Terminals can drop the second key of a mapping ("y" then Return) if both
    /// arrive in the same run loop pass.
    private static let keyStagger: TimeInterval = 0.05

    /// Shows the system dialog directing the user to Privacy & Security ▸ Accessibility.
    static func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func approve(session: Session, keys: [CGKeyCode]) {
        let target: String
        if session.entrypoint == "antigravity-app" {
            // Desktop Antigravity sessions live in the app, not a terminal.
            target = "Antigravity"
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
            target = AgentActions.terminalAppName(for: session.termProgram)
            AgentActions.focusTerminal(named: session.termProgram)
        }
        waitForFront(target, deadline: Date().addingTimeInterval(activationDeadline)) {
            send(keys, to: target)
        }
    }

    /// True once `name` owns the keyboard. Matched against both the localized name
    /// and the bundle's file name, which disagree for some apps (iTerm2, Code).
    private static func isFront(_ name: String) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let bundleName = app.bundleURL?.deletingPathExtension().lastPathComponent
        return app.localizedName?.caseInsensitiveCompare(name) == .orderedSame
            || bundleName?.caseInsensitiveCompare(name) == .orderedSame
    }

    private static func waitForFront(_ name: String, deadline: Date, then body: @escaping () -> Void) {
        if isFront(name) { body(); return }
        guard Date() < deadline else {
            NSLog("AgentBar: \(name) did not come forward; approval keystroke not sent")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            waitForFront(name, deadline: deadline, then: body)
        }
    }

    /// Re-checks the front app before every key: focus can change mid-sequence.
    private static func send(_ keys: [CGKeyCode], to target: String) {
        guard let key = keys.first else { return }
        guard isFront(target) else {
            NSLog("AgentBar: \(target) lost focus; approval keystroke not sent")
            return
        }
        post(key)
        let rest = Array(keys.dropFirst())
        guard !rest.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + keyStagger) { send(rest, to: target) }
    }

    /// Flags are cleared explicitly: a modifier the user happens to be holding
    /// would otherwise ride along and turn Return into Cmd+Return.
    private static func post(_ key: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }
}
