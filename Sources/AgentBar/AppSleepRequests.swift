import Foundation
import IOKit.pwr_mgt
import notify

/// Apps that have asked macOS not to sleep right now — an editor exporting, a
/// browser downloading, `caffeinate` in a terminal. macOS honours such a request
/// only while the lid is open, and "Sleep When Agents Are Done" would cut it short,
/// so Keep Awake reads them: as a trigger the person may switch on, and as a reason
/// to put off a sleep.
///
/// System daemons hold these requests all the time for reasons of their own and do
/// not count; Apple's apps (Photos, QuickTime Player, Finder copying) do. AgentBar's
/// own request never counts, and neither does one an agent's CLI makes for itself —
/// Claude Code runs `caffeinate -i -t 300` while it works — since the hooks already
/// say, more precisely, when an agent works.
enum AppSleepRequests {
    /// The assertion types that keep the Mac itself up. Display-only requests (a
    /// video playing) let the Mac sleep once the screen does, so they are not work.
    static let sleepTypes: Set<String> = ["PreventUserIdleSystemSleep", "NoIdleSleepAssertion", "PreventSystemSleep"]
    private static let systemPaths = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
    private static let systemApps = ["/System/Applications/", "/System/Library/CoreServices/Finder.app/"]
    /// Agent CLIs whose own children's requests are theirs, matched against the
    /// folders of the parent's executable too: Claude Code's is
    /// `~/.local/share/claude/versions/2.1.296`, named after its version.
    static let agentCLIs: Set<String> = ["claude", "codex", "gemini", "qwen", "opencode", "cursor-agent",
                                         "copilot", "droid", "amp", "goose", "aider", "devin"]

    /// The app an executable belongs to — its outermost `.app`, so a helper stands
    /// for its app — or the executable itself; nil for system processes.
    static func owner(path: String) -> String? {
        guard !path.isEmpty else { return nil }
        if !systemApps.contains(where: path.hasPrefix), systemPaths.contains(where: path.hasPrefix) { return nil }
        return path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" } ?? path
    }

    /// What a person calls an owner: "Final Cut Pro", "caffeinate".
    static func name(ofOwner key: String) -> String {
        key.hasSuffix(".app")
            ? FileManager.default.displayName(atPath: key).replacingOccurrences(of: ".app", with: "")
            : (key as NSString).lastPathComponent
    }

    /// The names of the apps asking, sorted, from a pid → assertions table.
    /// `parentPath` is the executable path of a process's parent.
    static func asking(_ byProcess: [Int32: [[String: Any]]], ownPID: Int32,
                       path: (Int32) -> String, parentPath: (Int32) -> String) -> [String] {
        var owners = Set<String>()
        for (pid, list) in byProcess where pid != ownPID
            && list.contains(where: { sleepTypes.contains($0[kIOPMAssertionTypeKey] as? String ?? "") }) {
            if isAgent(parentPath(pid)) { continue }
            if let key = owner(path: path(pid)) { owners.insert(key) }
        }
        return owners.map(name(ofOwner:)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The apps asking right now.
    static func asking() -> [String] {
        var table: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&table) == kIOReturnSuccess,
              let raw = table?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var byProcess: [Int32: [[String: Any]]] = [:]
        for (pid, list) in raw { byProcess[pid.int32Value] = list }
        return asking(byProcess, ownPID: ProcessInfo.processInfo.processIdentifier, path: executablePath,
                      parentPath: { executablePath(parentPID($0)) })
    }

    static func isAgent(_ executable: String) -> Bool {
        executable.split(separator: "/").contains { agentCLIs.contains(String($0)) }
    }

    static func parentPID(_ pid: Int32) -> Int32 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return Int32(info.pbi_ppid)
    }

    static func executablePath(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Calls `onChange` when the requests may have changed: the power manager's
    /// notification, with a slow poll behind it in case it is coalesced away.
    final class Watch {
        private var token: Int32 = NOTIFY_TOKEN_INVALID
        private var timer: Timer?

        init(_ onChange: @escaping () -> Void) {
            notify_register_dispatch("com.apple.system.powermanagement.assertions", &token, .main) { _ in onChange() }
            let t = Timer(timeInterval: 30, repeats: true) { _ in onChange() }
            t.tolerance = 10
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }

        deinit {
            if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
            timer?.invalidate()
        }
    }
}
