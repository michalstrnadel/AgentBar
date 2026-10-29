import Cocoa

/// Which sessions the person is looking at right now: the terminal tab in front,
/// in the app in front, while they are at the keyboard. A cue or a banner for one
/// of those says what the screen already says, so `SoundCenter` and `Notifier`
/// leave them out.
///
/// Only what can be known without asking. The tab is read from iTerm2 and
/// Terminal, and only when macOS has already let AgentBar script them — the check
/// never asks (`AEDeterminePermissionToAutomateTarget`, ask = false), because a
/// permission prompt nobody clicked for is a window unfolding on its own. Any
/// other terminal is unknown, and unknown is "not looking": a cue is never
/// dropped on a guess.
final class LookingAt {
    static let shared = LookingAt()
    static let prefKey = "quietWhenLooking"
    static var enabled: Bool { UserDefaults.standard.object(forKey: prefKey) as? Bool ?? true }

    /// Read on the main queue; written there after each background look.
    private(set) var ids: Set<String> = []
    private let queue = DispatchQueue(label: "agentbar.looking-at", qos: .utility)
    private var timer: Timer?
    private var sessions: [Session] = []
    private var busy = false

    func isLooking(at sessionId: String) -> Bool { Self.enabled && ids.contains(sessionId) }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.look() }
    }

    func update(_ sessions: [Session]) { self.sessions = sessions }

    private func look() {
        guard Self.enabled, !busy, InputIdle.seconds() < 30,
              let front = NSWorkspace.shared.frontmostApplication,
              let bundle = front.bundleIdentifier
        else { if !ids.isEmpty { ids = [] }; return }
        let candidates = sessions.filter { $0.pid > 0 && $0.state != .idle }
        guard !candidates.isEmpty else { if !ids.isEmpty { ids = [] }; return }
        busy = true
        let frontPid = front.processIdentifier
        queue.async { [weak self] in
            let mine = candidates.filter { ProcessAncestry.hostApplication(of: $0.pid)?.processIdentifier == frontPid }
            var seen: Set<String> = []
            if !mine.isEmpty, let tty = Self.frontTTY(bundle: bundle) {
                for s in mine where TerminalFocus.tty(of: s.pid) == tty { seen.insert(s.id) }
            }
            DispatchQueue.main.async {
                self?.ids = seen
                self?.busy = false
            }
        }
    }

    /// The tty of the selected tab in the frontmost window, for the terminals that
    /// say so, when AgentBar may already ask them.
    static func frontTTY(bundle: String) -> String? {
        let script: String
        switch bundle {
        case "com.googlecode.iterm2":
            script = #"tell application "iTerm2" to return tty of current session of current tab of current window"#
        case "com.apple.Terminal":
            script = #"tell application "Terminal" to return tty of selected tab of front window"#
        default:
            return nil
        }
        guard mayScript(bundle) else { return nil }
        let out = TerminalFocus.run("/usr/bin/osascript", ["-e", script], timeout: 2)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.hasPrefix("/dev/") ? out : nil
    }

    /// Whether macOS already lets AgentBar send Apple events to `bundle` — asked
    /// without ever putting up the consent prompt.
    static func mayScript(_ bundle: String) -> Bool {
        var target = AEAddressDesc()
        let id = Array(bundle.utf8)
        guard AECreateDesc(DescType(typeApplicationBundleID), id, id.count, &target) == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard),
                                                     AEEventID(typeWildCard), false) == noErr
    }
}
