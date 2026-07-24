import Cocoa

/// Best-effort approval for agents without decision hooks (Codex, Copilot): bring
/// the session's terminal forward, then post the agent's approval keystroke.
/// Requires the Accessibility permission; the menu labels the action honestly
/// ("sends keystroke") because delivery to the right tab is not guaranteed.
enum KeystrokeApprover {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system dialog directing the user to Privacy & Security ▸ Accessibility.
    static func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func approve(session: Session, keys: [CGKeyCode]) {
        if session.entrypoint == "antigravity-app" {
            // Desktop Antigravity sessions live in the app, not a terminal.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", "Antigravity"]
            try? p.run()
        } else {
            StatusItemController.focusTerminal(named: session.termProgram)
        }
        // Give the target time to come forward before typing into it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            for key in keys { post(key) }
        }
    }

    private static func post(_ key: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
