import Foundation

/// What a finished turn left running: a shell, a subagent, a monitor — work that
/// will wake the session again — and how many wakeups it has scheduled. Claude
/// Code lists both on Stop (`background`, `wakeups` in docs/protocol.md), so a
/// "done" row can say it is not quite.
struct BackgroundWork: Equatable {
    struct Task: Equatable {
        let type: String
        let what: String
    }

    var tasks: [Task] = []
    var wakeups = 0

    var isEmpty: Bool { tasks.isEmpty && wakeups == 0 }

    init(tasks: [Task] = [], wakeups: Int = 0) {
        self.tasks = tasks
        self.wakeups = wakeups
    }

    init?(_ tasks: Any?, wakeups: Any?) {
        let list = (tasks as? [[String: Any]] ?? []).prefix(5).compactMap { o -> Task? in
            guard let type = o["type"] as? String, !type.isEmpty else { return nil }
            return Task(type: String(type.prefix(20)), what: String((o["what"] as? String ?? "").prefix(60)))
        }
        let n = min(max((wakeups as? NSNumber)?.intValue ?? 0, 0), 99)
        guard !list.isEmpty || n > 0 else { return nil }
        self.init(tasks: list, wakeups: n)
    }

    /// "2 still running · shell, subagent" / "wakes again later".
    var text: String {
        var parts: [String] = []
        if !tasks.isEmpty {
            let kinds = tasks.map(\.type).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            parts.append("\(tasks.count) still running · " + kinds.joined(separator: ", "))
        }
        if wakeups > 0 {
            parts.append(wakeups == 1 ? "wakes again later" : "\(wakeups) wakeups scheduled")
        }
        return parts.joined(separator: " · ")
    }

    /// One line per task, for a tooltip.
    var detail: String {
        tasks.map { $0.what.isEmpty ? $0.type : "\($0.type): \($0.what)" }.joined(separator: "\n")
    }
}
