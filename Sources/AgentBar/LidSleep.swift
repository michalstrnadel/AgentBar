import Foundation
import IOKit

/// Awake with the lid closed — the one part of Keep Mac Awake that needs root.
///
/// macOS sleeps a closed laptop whatever any assertion says, unless sleep is
/// disabled outright (`pmset -a disablesleep 1`). That setting is dangerous in a
/// way the rest of the feature is not: it outlives the app that set it, so a crash
/// would leave a Mac that never sleeps — in a bag, hot, until the battery is flat.
/// So it is never left to the app's good behaviour:
///
/// - It starts only from a click, with the system's own password dialog, once.
/// - The same root command starts a small watcher that turns sleep back on by
///   itself as soon as AgentBar's process is gone (quit, crash, update), a stop
///   file appears in `~/.agentbar`, or a hard deadline passes — at most 12 hours.
///   Turning it off is writing that file, so it needs no second password.
///   Killed instead — a shutdown or restart sends it TERM — it turns sleep back
///   on as it goes, because a reboot would otherwise keep the setting.
/// - A marker records that it was started. If the Mac rebooted while it was on
///   (the watcher dies, the setting stays), the next launch sees marker + sleep
///   still disabled and offers **Restore…** in the menu and Settings. It never
///   asks for a password by itself: a dialog that appears unasked is a surface
///   opening on its own.
/// - Sleep disabled with no marker at all is not provably ours — another app, a
///   `pmset` in a terminal, or a watcher that died without a trace — so it is not
///   called a leftover, but it is still said: a Mac that never sleeps is worth a
///   menu row (`sleepOffElsewhere`), and the same click restores it.
/// - Whenever sleep comes back on with the lid closed, the watcher puts the Mac to
///   sleep. The lid closed while sleep was off, and macOS sleeps on the lid's
///   event, not its state: left alone, the Mac would stay up in the bag.
/// - Another app or a `pmset` in a terminal can turn sleep back on underneath it.
///   Putting it back would take the password again, so the session ends instead
///   and says so (`interrupted`), and a click starts it again.
final class LidSleep {
    static let shared = LidSleep()
    static let maxDuration: TimeInterval = 12 * 3600
    static let pollSeconds = 5

    private(set) var isOn = false
    /// When the root watcher turns sleep back on by itself, while it runs.
    private(set) var deadline: Date?
    private(set) var isStarting = false
    /// Why the last start did not happen ("" when it did, or nothing was tried).
    private(set) var lastError = ""
    /// The last session ended because something else turned sleep back on. Cleared
    /// by the next start, or `clearInterrupted`.
    private(set) var interrupted = false

    var stopFile: URL { AgentBarHome.url("awake-lid.stop") }
    var marker: URL { AgentBarHome.url("awake-lid.json") }

    /// Whether macOS has sleep disabled right now. Read from the power manager's
    /// registry entry, which needs no root.
    static func sleepDisabled() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
    }

    /// The lid is closed and that puts the Mac to sleep — not a Mac running closed
    /// on an external display.
    static func lidClosedSleeps() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        func flag(_ key: String) -> Bool {
            let value = IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
            return (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
        }
        return flag("AppleClamshellState") && flag("AppleClamshellCausesSleep")
    }

    /// A running session whose sleep was turned back on by something else: before
    /// the deadline, when the watcher itself would do it.
    static func wasTurnedOffUnderneath(isOn: Bool, deadline: Date?, now: Date, sleepDisabled: Bool) -> Bool {
        guard isOn, let deadline else { return false }
        return now < deadline && !sleepDisabled
    }

    /// Ends the session if something else turned sleep back on. True when it did.
    func checkStillHeld(now: Date = Date()) -> Bool {
        guard Self.wasTurnedOffUnderneath(isOn: isOn, deadline: deadline, now: now,
                                          sleepDisabled: Self.sleepDisabled()) else { return false }
        stop()
        interrupted = true
        return true
    }

    func clearInterrupted() { interrupted = false }

    /// For the demo generator: the page as it reads after an interruption.
    func setInterruptedForVerification(_ on: Bool) { interrupted = on }

    /// Sleep is still off from a session this process did not start — after a
    /// reboot, or a watcher that never ran.
    static func isLeftover(markerExists: Bool, sleepDisabled: Bool, ownSession: Bool) -> Bool {
        markerExists && sleepDisabled && !ownSession
    }

    var hasLeftover: Bool {
        Self.isLeftover(markerExists: FileManager.default.fileExists(atPath: marker.path),
                        sleepDisabled: Self.sleepDisabled(), ownSession: isOn || isStarting)
    }

    /// Sleep is disabled on this Mac and nothing says by whom.
    static func isSleepOffElsewhere(markerExists: Bool, sleepDisabled: Bool, ownSession: Bool) -> Bool {
        !markerExists && sleepDisabled && !ownSession
    }

    var sleepOffElsewhere: Bool {
        Self.isSleepOffElsewhere(markerExists: FileManager.default.fileExists(atPath: marker.path),
                                 sleepDisabled: Self.sleepDisabled(), ownSession: isOn || isStarting)
    }

    /// Starts it: one password dialog, then sleep disabled under the watcher.
    /// `completion` runs on the main queue with whether it is now on.
    func start(until deadline: Date, completion: @escaping (Bool) -> Void) {
        guard !isOn, !isStarting else { completion(isOn); return }
        isStarting = true
        lastError = ""
        interrupted = false
        let end = min(deadline, Date().addingTimeInterval(Self.maxDuration))
        try? FileManager.default.createDirectory(at: AgentBarHome.root(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: stopFile)
        let note = #"{"started":\#(Int(Date().timeIntervalSince1970)),"until":\#(Int(end.timeIntervalSince1970))}"#
        try? note.write(to: marker, atomically: true, encoding: .utf8)
        let script = Self.rootScript(pid: ProcessInfo.processInfo.processIdentifier,
                                     stopFile: stopFile.path, deadline: Int(end.timeIntervalSince1970))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (ok, message) = Self.runAsAdmin(script)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isStarting = false
                self.isOn = ok
                self.deadline = ok ? end : nil
                self.lastError = ok ? "" : message
                if !ok { try? FileManager.default.removeItem(at: self.marker) }
                completion(ok)
            }
        }
    }

    /// Turns sleep back on through the watcher: no password.
    func stop() {
        guard isOn else { return }
        isOn = false
        deadline = nil
        try? "stop".write(to: stopFile, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: marker)
    }

    /// Restores sleep left disabled by an earlier session. Asks for the password,
    /// because nothing of ours is running as root to do it.
    func restoreLeftover(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (ok, _) = Self.runAsAdmin("/usr/bin/pmset -a disablesleep 0",
                                          prompt: "AgentBar wants to let this Mac sleep again.")
            DispatchQueue.main.async {
                if ok, let self { try? FileManager.default.removeItem(at: self.marker) }
                completion(ok)
            }
        }
    }

    // MARK: - The root command

    /// Single-quoted for /bin/sh: the one quoting that needs no other escaping,
    /// with any `'` in the path closed, escaped and reopened.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Sleeps the Mac if its lid is closed and that would sleep it. Unquoted
    /// patterns (`.` for the `" ` around `=`) keep it free of quotes to escape.
    /// No temporary file: root writing to a guessable path is a hole of its own.
    static let sleepIfLidClosed = "{ /usr/sbin/ioreg -r -k AppleClamshellState -d 1 "
        + "| /usr/bin/grep -q AppleClamshellState..=.Yes && /usr/sbin/ioreg -r -k AppleClamshellState -d 1 "
        + "| /usr/bin/grep -q AppleClamshellCausesSleep..=.Yes && /usr/bin/pmset sleepnow; }"

    /// What runs as root. Every value in it is ours — a pid, an epoch second, a
    /// path inside AgentBar's own folder — and the path is quoted all the same.
    static func rootScript(pid: Int32, stopFile: String, deadline: Int) -> String {
        let stop = shellQuote(stopFile)
        let loop = "trap \"/usr/bin/pmset -a disablesleep 0; exit 0\" TERM INT; "
            + "while :; do sleep \(pollSeconds); "
            + "if ! /bin/kill -0 \(pid) 2>/dev/null || [ -e \(stop) ] || [ $(/bin/date +%s) -ge \(deadline) ]; "
            + "then /usr/bin/pmset -a disablesleep 0; \(sleepIfLidClosed); exit 0; fi; done"
        return "/usr/bin/pmset -a disablesleep 1 && "
            + "(/usr/bin/nohup /bin/sh -c \(shellQuote(loop)) >/dev/null 2>&1 &)"
    }

    /// The AppleScript string literal for `shell`.
    static func appleScriptLiteral(_ shell: String) -> String {
        "\"" + shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func runAsAdmin(_ shell: String,
                                   prompt: String = "AgentBar wants to keep this Mac awake with the lid closed.")
        -> (Bool, String) {
        let source = "do shell script \(appleScriptLiteral(shell)) with administrator privileges "
            + "with prompt \(appleScriptLiteral(prompt))"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return (false, "Could not ask for the password") }
        p.waitUntilExit()
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if p.terminationStatus == 0 { return (true, "") }
        // -128 is the person pressing Cancel: not an error worth a sentence.
        return (false, text.contains("-128") ? "Cancelled" : "macOS refused the change")
    }
}
