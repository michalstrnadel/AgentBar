import Foundation

/// Raises a real approval, through the real hook, and waits for you to answer it.
///
/// Every other check in `Diagnostics` reads a file and reasons about it. This one
/// runs the path: it starts the installed `permission.js` exactly the way an agent
/// does, which writes a request into `requests.d`; the app picks it up and shows a
/// card like any other; you answer it; and the hook prints the decision the agent
/// would have received. Nothing is simulated and nothing is special-cased — if this
/// works, remote approval works on this Mac, and if it does not, the report says
/// which end of it broke.
///
/// It exists because the feature the whole product is built on had never once been
/// exercised end to end on the author's own machine (issue #1): the ledger here was
/// empty, because Claude runs in auto mode and no prompt ever fires.
enum ApprovalSelfTest {
    enum Outcome: Equatable {
        /// The hook printed a decision — the whole path works. Carries `allow`/`deny`.
        case answered(String)
        /// Nobody answered before the hook gave up. Not a failure of the wiring.
        case timedOut
        /// The hook ran and said nothing, which is the fall-through contract working
        /// — but it means the request never reached anybody.
        case fellThrough
        case noNode
        case noHook
        case failed(String)

        var line: String {
            switch self {
            case .answered(let behavior):
                return "Answered “\(behavior)” — the whole path works: hook, request, card, answer."
            case .timedOut:      return "Nobody answered it in time. The card was raised; the wiring is fine."
            case .fellThrough:   return "The hook gave up without a decision — the request never reached a card."
            case .noNode:        return "No node found, so no hook can run. Diagnostics says where it looked."
            case .noHook:        return "permission.js is not installed. Re-install the hooks and try again."
            case .failed(let why): return "Could not run the hook: \(why)"
            }
        }
    }

    /// The session this borrows. It is deleted afterwards, so the card it raises
    /// does not leave a session behind that never existed.
    static let sessionID = "agentbar-self-test"

    /// Runs the hook and calls back on the main queue. `timeout` is the hook's own
    /// wait, so the test ends when the hook does rather than racing it.
    static func run(timeout: TimeInterval = 90,
                    base: URL = AgentBarHome.root(),
                    completion: @escaping (Outcome) -> Void) {
        func finish(_ outcome: Outcome) {
            cleanUp(base: base)
            DispatchQueue.main.async { completion(outcome) }
        }
        guard let node = HookInstaller.resolvedNode else { return finish(.noNode) }
        let hook = HookInstaller.installedHooks.appendingPathComponent("claude/permission.js")
        guard FileManager.default.fileExists(atPath: hook.path) else { return finish(.noHook) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: node)
        task.arguments = [hook.path]
        var env = ProcessInfo.processInfo.environment
        env["AGENTBAR_APPROVAL_TIMEOUT"] = String(Int(timeout))
        // The hook checks for a frontend before it writes anything, and the frontend
        // it is looking for is this process.
        env["AGENTBAR_FORCE_APP"] = "1"
        task.environment = env

        let stdin = Pipe(), stdout = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice

        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            do { try task.run() } catch { return finish(.failed(error.localizedDescription)) }
            stdin.fileHandleForWriting.write(payload)
            try? stdin.fileHandleForWriting.close()
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard !out.isEmpty else {
                // Silence is the contract working, and there are two of them.
                return finish(silence(after: Date().timeIntervalSince(started), timeout: timeout))
            }
            guard let json = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
                  let specific = json["hookSpecificOutput"] as? [String: Any],
                  let decision = specific["decision"] as? [String: Any],
                  let behavior = decision["behavior"] as? String
            else { return finish(.failed("the hook printed something this cannot read")) }
            finish(.answered(behavior))
        }
    }

    /// Which of the two silences this was.
    ///
    /// The exit code cannot tell them apart — every fall-through path in
    /// `permission.js` exits 0 and prints nothing, which is the whole point of the
    /// contract — so asking it produced one answer for both cases and the other
    /// wording was unreachable. The clock can tell them apart: a hook that reached
    /// its deadline waited the entire time it was given, and one that never got as
    /// far as a card came back long before. Two seconds of slack for a process that
    /// still has to start, read stdin and exit.
    static func silence(after elapsed: TimeInterval, timeout: TimeInterval) -> Outcome {
        elapsed >= timeout - 2 ? .timedOut : .fellThrough
    }

    /// What an agent would send for a harmless command. `AGENTBAR_AGENT` is left
    /// alone: the request has to look like a real one for the card to render, and
    /// inventing an agent id would only mean inventing a sprite for it too.
    private static var payload: Data {
        let event: [String: Any] = [
            "session_id": sessionID,
            "prompt_id": "self-test",
            "tool_name": "Bash",
            "tool_input": ["command": "echo \"AgentBar can ask you things\""],
            "cwd": FileManager.default.homeDirectoryForCurrentUser.path,
        ]
        return (try? JSONSerialization.data(withJSONObject: event)) ?? Data()
    }

    /// The hook writes a session row so the menu can show what is pending. That
    /// session does not exist, so it does not get to outlive the test.
    private static func cleanUp(base: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: base.appendingPathComponent("state.d/\(sessionID).json"))
        for dir in ["requests.d", "answers.d"] {
            let url = base.appendingPathComponent("\(dir)/\(sessionID)-self-test.json")
            try? fm.removeItem(at: url)
        }
    }
}
