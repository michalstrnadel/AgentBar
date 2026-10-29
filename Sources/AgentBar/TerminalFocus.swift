import Cocoa

/// Tab-precision jump-back: land on the exact terminal tab or split pane the
/// session runs in, not just its app. The session's pid (the agent process) has a
/// controlling tty; iTerm2 and Terminal.app expose each tab's tty to AppleScript,
/// WezTerm to its own CLI, tmux to `list-panes` — matching the two is the whole
/// trick. Everything here is best effort on a background queue: any miss (no tty,
/// scripting denied, app too old) leaves the plain app-level focus that always
/// runs as the floor.
///
/// What each host can be asked for, and how much of it is proven:
///
/// - **iTerm2, Terminal.app, WezTerm** — the tab by tty, reported as a hit or a
///   miss. These are the only hosts a keystroke may be aimed at directly.
/// - **tmux**, in any of those three — the pane by tty, then the outer tab by the
///   tmux client's tty (`TmuxFocus`). Aimable only when both halves report a hit.
/// - **kitty** — `kitty @ focus-window`, which works only for a user who set
///   `listen_on` and allowed remote control, and says nothing we could check the
///   landing against. Focus, never a target.
/// - **Ghostty** — its AppleScript dictionary (1.3) lists terminals by working
///   directory and can focus one, but exposes neither tty nor pid. The only honest
///   match is "the one terminal in this directory"; two in the same directory and
///   it stays at app level. Focus, never a target.
/// - **Editors** (VS Code, Cursor, Zed, …) — the app found by process ancestry,
///   then its window for the session's folder. Focus, never a target.
/// - **Anything else** — the app found by process ancestry, which is still the
///   right app even when TERM_PROGRAM names none.
enum TerminalFocus {
    /// One attempt at a time: a stuck attempt (the Automation consent prompt
    /// can hold osascript for a minute) must queue later clicks, not stack one
    /// blocked thread per click.
    private static let queue = DispatchQueue(label: "agentbar.terminalfocus", qos: .userInitiated)

    /// Whether this terminal can be asked to bring a specific tab forward. A
    /// caller about to TYPE into the session has to know: posting a keystroke
    /// at a terminal we can't aim would hit whatever tab happened to be open.
    ///
    /// This is a promise about the *attempt*, not the outcome — `focus` still
    /// reports the landing, and callers type only on a reported one. So a host
    /// earns a place here only when its select can come back as a verified hit.
    /// tmux is on the list because its landing is verified twice (the pane, then
    /// the outer terminal's tab by the client's tty) and anything short of both
    /// reports no landing; kitty and Ghostty are not, because neither says which
    /// window it brought forward, and "probably the right one" is how a keystroke
    /// approves somebody else's session.
    static func canTargetTab(termProgram: String) -> Bool {
        ["iTerm.app", "Apple_Terminal", "WezTerm", "tmux"].contains(termProgram)
    }

    /// `done` runs on the main queue once the tab select has finished (or
    /// immediately, when there is nothing to select). It carries the name of the
    /// app now showing the session's own tab in front — nil unless that was
    /// verified, and only a non-nil answer makes it safe to type. It is a name and
    /// not a flag because the app to wait for is not always the one TERM_PROGRAM
    /// names: a tmux session's tab lives in whichever terminal runs the client.
    static func focus(session: Session, done: ((String?) -> Void)? = nil) {
        let term = session.termProgram
        let pid = session.pid
        let cwd = session.cwd
        // The floor first and instantly: the user clicked, so the app comes
        // forward now. The precise tab select runs behind it and may land
        // seconds later — first use waits on the Automation consent prompt.
        // The floor is the app the agent actually runs in when its ancestry says
        // so (a `sysctl` walk, microseconds), and the app TERM_PROGRAM names only
        // when it does not. "tmux" names no app: its floor comes from the client.
        let host = ProcessAncestry.hostApplication(of: pid)
            .flatMap { $0.processIdentifier == getpid() ? nil : $0 }
        if let host {
            activate(host)
        } else if term != "tmux" {
            AgentActions.focusTerminal(named: term)
        }
        let hostBundleID = host?.bundleIdentifier
        let hostPid = host?.processIdentifier
        queue.async {
            let landed = aim(term: term, pid: pid, cwd: cwd,
                             hostBundleID: hostBundleID, hostPid: hostPid)
            if let done { DispatchQueue.main.async { done(landed) } }
        }
    }

    /// The precise half, off the main thread. Returns the name `done` reports.
    private static func aim(term: String, pid: Int32, cwd: String,
                            hostBundleID: String?, hostPid: Int32?) -> String? {
        let tty = tty(of: pid)
        // tmux before anything else, whatever TERM_PROGRAM says: a tmux older
        // than 3.2 leaves the outer terminal's value in place, and a pane's tty
        // matches no terminal's tab list anyway. Costs nothing without tmux —
        // no socket directory, no process spawned.
        if let tty, let outcome = TmuxFocus.focus(tty: tty) {
            return landTmuxClient(outcome)
        }
        switch term {
        case "iTerm.app":
            if let tty, selectITermSession(tty: tty) { return TerminalApp.appName(forTermProgram: term) }
        case "Apple_Terminal":
            // "" deliberately doesn't match: an unknown terminal must not
            // trigger a Terminal.app Automation prompt for nothing.
            if let tty, selectTerminalTab(tty: tty) { return TerminalApp.appName(forTermProgram: term) }
        case "WezTerm":
            if let tty, activateWezTermPane(tty: tty) { return TerminalApp.appName(forTermProgram: term) }
        case "ghostty":
            _ = focusGhosttyTerminal(cwd: cwd)          // focus only — see the type's doc
        case "kitty":
            _ = focusKittyWindow(pid: pid, kittyPid: hostPid)  // focus only
        default:
            // Warp, Alacritty, editors, anything unlisted: the ancestry floor
            // already brought the right app forward. An editor can do one better.
            if let hostBundleID { openFolder(cwd, inEditor: hostBundleID) }
        }
        return nil
    }

    /// The outer half of a tmux jump: bring forward the terminal hosting the
    /// chosen client, then select that terminal's tab by the client's tty. The
    /// landing is reported only when the pane select AND the tab select both hit
    /// — either one alone could leave the keyboard on another session.
    private static func landTmuxClient(_ outcome: TmuxFocus.Outcome) -> String? {
        guard let client = outcome.client,
              let app = ProcessAncestry.hostApplication(of: client.pid) else { return nil }
        activate(app)
        guard outcome.paneSelected,
              let terminal = TerminalApp.known(bundleID: app.bundleIdentifier) else { return nil }
        let hit: Bool
        switch terminal.termProgram {
        case "iTerm.app":      hit = selectITermSession(tty: client.tty)
        case "Apple_Terminal": hit = selectTerminalTab(tty: client.tty)
        case "WezTerm":        hit = activateWezTermPane(tty: client.tty)
        default:               hit = false   // the app is right; its tab is unproven
        }
        return hit ? terminal.name : nil
    }

    /// Activate a running app through LaunchServices, the same road `open -a`
    /// takes, rather than `NSRunningApplication.activate`: since macOS 14 an app
    /// that is not itself active may be refused a direct activation, and a click
    /// in a menu bar item does not reliably make AgentBar the active app.
    private static func activate(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// "/dev/ttys003" for a live process, nil for daemons ("??") or a dead pid.
    static func tty(of pid: Int32) -> String? {
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

    /// Ghostty: its dictionary (checked against the `Ghostty.sdef` 1.3.1 ships)
    /// has `terminals` with a `working directory` and a `focus` command that
    /// brings the terminal's window to the front — and no tty, no pid. So this
    /// focuses a terminal only when exactly one sits in the session's directory:
    /// with two, either could be the agent and neither is chosen. The directory is
    /// what the shell last reported (Ghostty's shell integration), so an agent
    /// that `cd`s after launch, or a shell without the integration, simply misses.
    /// A hit here is a guess that happened to be unique, which is why it is never
    /// reported as a landing.
    private static func focusGhosttyTerminal(cwd: String) -> Bool {
        let dir = cwd.count > 1 && cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        guard !dir.isEmpty else { return false }
        let script = """
        on run argv
            set target to item 1 of argv
            tell application "Ghostty"
                set hits to {}
                repeat with t in terminals
                    if working directory of t is target then set end of hits to contents of t
                end repeat
                if (count of hits) is not 1 then return "miss"
                focus (item 1 of hits)
            end tell
            return "hit"
        end run
        """
        return run("/usr/bin/osascript", ["-e", script, dir], timeout: 60)?
            .contains("hit") == true
    }

    /// Where kitty's CLI lives: inside the app bundle for the usual install, on
    /// Homebrew's path for the cask's symlink.
    private static let kittyCandidates = ["/Applications/kitty.app/Contents/MacOS/kitty",
                                          "/opt/homebrew/bin/kitty", "/usr/local/bin/kitty"]

    /// kitty: `kitty @ focus-window`, over a remote-control socket. It works only
    /// for a user who set `listen_on unix:/tmp/<name>` and `allow_remote_control`;
    /// kitty's default is neither. Outside a kitty window `kitty @` has no tty to
    /// talk over and `KITTY_LISTEN_ON` is in the agent's environment, not ours, so
    /// the socket is looked for where people put it (`kittySockets`). Abstract
    /// sockets (`unix:@name`) are Linux-only and never arise here.
    private static func focusKittyWindow(pid: Int32, kittyPid: Int32?) -> Bool {
        guard let kitty = kittyCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let match = kittyMatch(pids: ProcessAncestry.liveChain(from: pid))
        else { return false }
        for socket in kittySockets(kittyPid: kittyPid) {
            if run(kitty, ["@", "--to", "unix:" + socket, "focus-window", "--match", match]) != nil {
                return true
            }
        }
        return false
    }

    /// kitty's `pid:` matches the process a window started — the shell — not the
    /// agent the shell forked, so the match names the agent and every ancestor,
    /// and the window whose child is among them is the one. Nil with no pid.
    static func kittyMatch(pids: [Int32]) -> String? {
        pids.isEmpty ? nil : pids.map { "pid:\($0)" }.joined(separator: " or ")
    }

    /// Sockets named like kitty's, in `/tmp` and the per-user temporary directory.
    private static func kittySockets(kittyPid: Int32?) -> [String] {
        let fm = FileManager.default
        let dirs = ["/tmp", NSTemporaryDirectory()]
        let paths = dirs.flatMap { dir -> [String] in
            let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            return names.filter { $0.localizedCaseInsensitiveContains("kitty") }
                .map { URL(fileURLWithPath: dir).appendingPathComponent($0).path }
        }
        .filter { (try? fm.attributesOfItem(atPath: $0)[.type] as? FileAttributeType) == .typeSocket }
        return orderKittySockets(paths, kittyPid: kittyPid)
    }

    /// kitty appends its own pid to a `listen_on` path (`/tmp/mykitty-4242`), so
    /// when ancestry found the kitty hosting the agent, its socket is tried first
    /// and a leftover from a kitty that has since quit comes last. Stable
    /// otherwise, and duplicates (a `$TMPDIR` that is `/tmp`) are tried once.
    static func orderKittySockets(_ paths: [String], kittyPid: Int32?) -> [String] {
        var seen = Set<String>()
        let unique = paths.filter { seen.insert($0).inserted }
        guard let kittyPid else { return unique }
        let mine = unique.filter { $0.hasSuffix("-\(kittyPid)") }
        return mine + unique.filter { !$0.hasSuffix("-\(kittyPid)") }
    }

    /// Editors that, handed a folder already open in one of their windows, bring
    /// that window forward — VS Code and its forks by default, Zed by design. The
    /// integrated terminal lives in the window for the workspace, so the folder is
    /// the way to the right window when the app has several. Deliberately not
    /// `code -r`, which *replaces* the frontmost window's folder when the session's
    /// is not open, and deliberately not JetBrains, whose IDEs treat an opened
    /// folder as a project to import. The limit: a session started in a subfolder
    /// of the workspace opens that subfolder as a new window.
    static let folderOpeningEditors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "dev.zed.Zed", "dev.zed.Zed-Preview",
    ]

    private static func openFolder(_ cwd: String, inEditor bundleID: String) {
        var isDir: ObjCBool = false
        guard folderOpeningEditors.contains(bundleID), !cwd.isEmpty,
              FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Plumbing

    /// Run a tool, give it a moment, and hand back stdout. Nil on any failure —
    /// callers treat every miss the same way: the app-level focus already ran.
    /// osascript gets a generous window because its first run blocks on the
    /// Automation consent prompt; killing it under the user would eat the dialog.
    /// Stdout drains as it arrives — waiting for exit before reading deadlocks
    /// the moment output outgrows the pipe buffer (a long `wezterm cli list`).
    /// Internal rather than private so `TmuxFocus` runs its commands the same way.
    static func run(_ path: String, _ args: [String],
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
