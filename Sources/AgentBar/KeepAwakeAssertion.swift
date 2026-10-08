import Foundation

/// Holds the power assertion that keeps the Mac (and maybe its display) awake.
///
/// One activity token at a time, renewed only when what it says changes — no timer, no
/// timeout to renew, so no gap in which the Mac can drop off (a renewal loop that
/// recreates an 8-second assertion every 10 seconds leaves two seconds of every
/// ten unguarded). The system releases it when the process exits, crash included,
/// and `pmset -g assertions` shows it with `reason`.
final class KeepAwakeAssertionHolder {
    private var token: NSObjectProtocol?
    private(set) var kind: KeepAwakeAssertion = .none
    private var reason = ""

    /// Holds `kind` with `reason` as its name. A new reason (a countdown that moved,
    /// "agents done") takes a new token before the old one is let go, so what
    /// `pmset -g assertions` shows is always true and never has a gap.
    func apply(_ kind: KeepAwakeAssertion, reason: String) {
        guard kind != self.kind || (kind != .none && reason != self.reason) else { return }
        let old = token
        token = nil
        self.kind = kind
        self.reason = reason
        // `pmset` prints the name as ASCII; a middle dot came out as a box.
        let name = "AgentBar: " + reason.replacingOccurrences(of: " · ", with: ", ")
            .replacingOccurrences(of: " — ", with: " - ")
        switch kind {
        case .none:
            break
        case .system:
            token = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                          reason: name)
        case .systemAndDisplay:
            token = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled], reason: name)
        }
        if let old { ProcessInfo.processInfo.endActivity(old) }
    }

    deinit {
        if let token { ProcessInfo.processInfo.endActivity(token) }
    }
}
