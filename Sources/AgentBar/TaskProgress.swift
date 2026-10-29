import Foundation

/// How far along the agent's own task list is: Claude Code's TodoWrite, as the
/// hook wrote it into the row (`todo: {done, total, now}`). Drawn as a thin bar
/// under a working session and "3/7 · Running tests" beside it — the agent's plan,
/// counted, never estimated.
struct TaskProgress: Equatable {
    let done: Int
    let total: Int
    /// The step in progress, in the agent's words ("Running tests"); may be empty.
    let now: String

    init?(_ raw: Any?) {
        guard let o = raw as? [String: Any],
              let total = (o["total"] as? NSNumber)?.intValue, total > 0, total <= 200,
              let done = (o["done"] as? NSNumber)?.intValue, done >= 0
        else { return nil }
        self.total = total
        self.done = min(done, total)
        self.now = String(ApprovalRequest.oneLine(o["now"] as? String ?? "").prefix(60))
    }

    init(done: Int, total: Int, now: String) {
        self.done = done; self.total = total; self.now = now
    }

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

    /// "3/7 · Running tests", or "3/7" when no step is in progress.
    var text: String { now.isEmpty ? "\(done)/\(total)" : "\(done)/\(total) · \(now)" }
}
