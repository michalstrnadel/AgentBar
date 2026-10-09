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
/// - A marker records that it was started. If the Mac rebooted while it was on
///   (the watcher dies, the setting stays), the next launch sees marker + sleep
///   still disabled and offers **Restore…** in the menu and Settings. It never
///   asks for a password by itself: a dialog that appears unasked is a surface
///   opening on its own.
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

    /// Sleep is still off from a session this process did not start — after a
    /// reboot, or a watcher that never ran.
    static func isLeftover(markerExists: Bool, sleepDisabled: Bool, ownSession: Bool) -> Bool {
        markerExists && sleepDisabled && !ownSession
    }

    var hasLeftover: Bool {
        Self.isLeftover(markerExists: FileManager.default.fileExists(atPath: marker.path),
                        sleepDisabled: Self.sleepDisabled(), ownSession: isOn || isStarting)
    }

    /// Starts it: one password dialog, then sleep disabled under the watcher.
    /// `completion` runs on the main queue with whether it is now on.
    func start(until deadline: Date, completion: @escaping (Bool) -> Void) {
        guard !isOn, !isStarting else { completion(isOn); return }
        isStarting = true
        lastError = ""
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
            let (ok, _) = Self.runAsAdmin("/usr/bin/pmset -a disablesleep 0")
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

    /// What runs as root. Every value in it is ours — a pid, an epoch second, a
    /// path inside AgentBar's own folder — and the path is quoted all the same.
    static func rootScript(pid: Int32, stopFile: String, deadline: Int) -> String {
        let stop = shellQuote(stopFile)
        let loop = "while :; do sleep \(pollSeconds); "
            + "if ! /bin/kill -0 \(pid) 2>/dev/null || [ -e \(stop) ] || [ $(/bin/date +%s) -ge \(deadline) ]; "
            + "then /usr/bin/pmset -a disablesleep 0; exit 0; fi; done"
        return "/usr/bin/pmset -a disablesleep 1 && "
            + "(/usr/bin/nohup /bin/sh -c \(shellQuote(loop)) >/dev/null 2>&1 &)"
    }

    /// The AppleScript string literal for `shell`.
    static func appleScriptLiteral(_ shell: String) -> String {
        "\"" + shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func runAsAdmin(_ shell: String) -> (Bool, String) {
        let source = "do shell script \(appleScriptLiteral(shell)) with administrator privileges "
            + "with prompt \"AgentBar wants to keep this Mac awake with the lid closed.\""
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
