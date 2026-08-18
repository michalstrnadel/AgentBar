import Cocoa

/// Tab-precision jump-back: land on the exact terminal tab or split pane the
/// session runs in, not just its app. The session's pid (the agent process) has a
/// controlling tty; iTerm2 and Terminal.app expose each tab's tty to AppleScript,
/// WezTerm to its own CLI — matching the two is the whole trick. Everything here
/// is best effort on a background queue: any miss (no tty, scripting denied, app
/// too old) leaves the plain app-level focus that always runs as the floor.
enum TerminalFocus {
    /// One attempt at a time: a stuck attempt (the Automation consent prompt
    /// can hold osascript for a minute) must queue later clicks, not stack one
    /// blocked thread per click.
    private static let queue = DispatchQueue(label: "agentbar.terminalfocus", qos: .userInitiated)

    /// Whether this terminal can be asked to bring a specific tab forward. A
    /// caller about to TYPE into the session has to know: posting a keystroke
    /// at a terminal we can't aim would hit whatever tab happened to be open.
    static func canTargetTab(termProgram: String) -> Bool {
        ["iTerm.app", "Apple_Terminal", "WezTerm"].contains(termProgram)
    }

    /// `done` runs on the main queue once the tab select has finished (or
    /// immediately, when there is nothing to select). It reports whether the
    /// session's own tab is now the front one — only then is it safe to type.
    static func focus(session: Session, done: ((Bool) -> Void)? = nil) {
        let term = session.termProgram
        let pid = session.pid
        // The floor first and instantly: the user clicked, so the app comes
        // forward now. The precise tab select runs behind it and may land
        // seconds later — first use waits on the Automation consent prompt.
        AgentActions.focusTerminal(named: term)
        queue.async {
            var targeted = false
            switch term {
            case "iTerm.app":
                if let tty = tty(of: pid) { targeted = selectITermSession(tty: tty) }
            case "Apple_Terminal":
                // "" deliberately doesn't match: an unknown terminal must not
                // trigger a Terminal.app Automation prompt for nothing.
                if let tty = tty(of: pid) { targeted = selectTerminalTab(tty: tty) }
            case "WezTerm":
                if let tty = tty(of: pid) { targeted = activateWezTermPane(tty: tty) }
            default:
                break // Warp, Ghostty, kitty, …: no per-tab targeting to offer
            }
            if let done { DispatchQueue.main.async { done(targeted) } }
        }
    }

    /// "/dev/ttys003" for a live process, nil for daemons ("??") or a dead pid.
    private static func tty(of pid: Int32) -> String? {
        guard pid > 0,
              let out = run("/bin/ps", ["-o", "tty=", "-p", "\(pid)"])?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty, out != "??"
        else { return nil }
        return "/dev/" + out
    }

    // MARK: - Per-terminal targeting

    /// iTerm2: windows ▸ tabs ▸ sessions, each with a `tty` — select all three.
    /// Prints "hit" when the tty was found, so the caller can tell a real
    /// selection from a silent miss.
    private static func selectITermSession(tty: String) -> Bool {
        let script = """
        on run argv
            set target to item 1 of argv
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is target then
                                select s
                                select t
                                select w
                                return "hit"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "miss"
        end run
        """
        return run("/usr/bin/osascript", ["-e", script, tty], timeout: 60)?
            .contains("hit") == true
    }

    /// Terminal.app: tabs carry the tty directly.
    private static func selectTerminalTab(tty: String) -> Bool {
        let script = """
        on run argv
            set target to item 1 of argv
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is target then
                            set selected of t to true
                            set frontmost of w to true
                            return "hit"
                        end if
                    end repeat
                end repeat
            end tell
            return "miss"
        end run
        """
        return run("/usr/bin/osascript", ["-e", script, tty], timeout: 60)?
            .contains("hit") == true
    }

    /// WezTerm: its own CLI lists panes with tty_name and can activate by id.
    private static func activateWezTermPane(tty: String) -> Bool {
        guard let wezterm = ["/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm",
                             "/Applications/WezTerm.app/Contents/MacOS/wezterm"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return false }
        guard let json = run(wezterm, ["cli", "list", "--format", "json"]),
              let data = json.data(using: .utf8),
              let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let pane = panes.first(where: { $0["tty_name"] as? String == tty }),
              let id = pane["pane_id"] as? Int
        else { return false }
        return run(wezterm, ["cli", "activate-pane", "--pane-id", "\(id)"]) != nil
    }

    // MARK: - Plumbing

    /// Run a tool, give it a moment, and hand back stdout. Nil on any failure —
    /// callers treat every miss the same way: the app-level focus already ran.
    /// osascript gets a generous window because its first run blocks on the
    /// Automation consent prompt; killing it under the user would eat the dialog.
    /// Stdout drains as it arrives — waiting for exit before reading deadlocks
    /// the moment output outgrows the pipe buffer (a long `wezterm cli list`).
    private static func run(_ path: String, _ args: [String],
                            timeout: TimeInterval = 8) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        var buffer = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); buffer.append(chunk); lock.unlock()
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if p.isRunning { p.terminate(); return nil }
        // A last drain — with the handler off first, so the two readers never
        // pull from the descriptor at the same time.
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            lock.lock(); buffer.append(rest); lock.unlock()
        }
        guard p.terminationStatus == 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }
}
