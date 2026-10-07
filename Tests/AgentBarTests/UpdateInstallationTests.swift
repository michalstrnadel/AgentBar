import Foundation
import Testing
@testable import AgentBar

/// The relaunch script is the one piece of the updater that runs after the app is
/// gone, so it is also the one piece nobody ever sees fail. These drive it against
/// throwaway directories standing in for the bundles, and a fake `open` that can be
/// told to refuse — the case that used to leave the Mac with no AgentBar at all.
@Suite struct UpdateInstallationTests {
    private let root: URL
    private let fm = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// A stand-in bundle whose `version` file says which one it is.
    private func bundle(_ name: String, version: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try version.write(to: url.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        return url
    }

    private func version(_ url: URL) throws -> String {
        try String(contentsOf: url.appendingPathComponent("version"), encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    /// Run the real script with a fake launcher in place of `/usr/bin/open`.
    /// The launcher is handed `-n <bundle>`, exactly as `open` would be, so a
    /// script of `[[ ... $2 ... ]]` can decide by looking at the bundle it was given.
    private func relaunch(current: URL, staging: URL, backup: URL,
                          launcherScript: String) throws -> Int32 {
        // A space in the name is not an accident: it is how a real /Applications
        // path behaves, and the script must survive it.
        let launcher = root.appendingPathComponent("fake launcher")
        try ("#!/bin/bash\n" + launcherScript + "\n").write(to: launcher, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", UpdateInstallation.relaunchScript, "agentbar-relaunch",
                             current.path, staging.path, backup.path, launcher.path]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test func successfulLaunchCleansBackupAndStaging() throws {
        let current = try bundle("AgentBar.app", version: "new")
        let backup = try bundle("backup.app", version: "old")
        let staging = try bundle("staging", version: "staged")

        #expect(try relaunch(current: current, staging: staging, backup: backup,
                             launcherScript: "exit 0") == 0)

        #expect(try version(current) == "new")
        #expect(!exists(backup))
        #expect(!exists(staging))
    }

    /// The regression this suite exists for: when the new bundle will not open,
    /// the old one goes back and gets launched instead of being deleted.
    @Test func failedLaunchRestoresOldBundleAndRelaunchesIt() throws {
        // The path is hostile on purpose — a quote and a command substitution that
        // would run if any of these paths reached the shell's parser unquoted.
        let current = try bundle("AgentBar ' $(touch injected).app", version: "new")
        let backup = try bundle("backup.app", version: "old")
        let staging = try bundle("staging", version: "staged")

        // Opens only the old bundle; the new one is rejected.
        let result = try relaunch(current: current, staging: staging, backup: backup,
                                  launcherScript: #"[[ "$(/bin/cat "$2/version")" == old ]]"#)

        #expect(result == 0)
        #expect(try version(current) == "old")
        #expect(!exists(staging))
        #expect(!exists(root.appendingPathComponent("injected")))
    }

    /// Nothing opens. The old bundle is still what sits in /Applications, and the
    /// staging dir survives so the failed download can be looked at.
    @Test func bothLaunchesFailKeepRestoredOldBundle() throws {
        let current = try bundle("AgentBar.app", version: "new")
        let backup = try bundle("backup.app", version: "old")
        let staging = try bundle("staging", version: "staged")

        #expect(try relaunch(current: current, staging: staging, backup: backup,
                             launcherScript: "exit 1") != 0)

        #expect(try version(current) == "old")
        #expect(exists(staging))
    }

    /// Nobody clicked the relaunch, so it is marked as a background launch and
    /// opens no window — the bundle is still `$2`, as `open` would be handed it.
    @Test func theRelaunchSaysItIsInTheBackground() throws {
        let current = try bundle("AgentBar.app", version: "new")
        let backup = try bundle("backup.app", version: "old")
        let staging = try bundle("staging", version: "staged")
        #expect(try relaunch(current: current, staging: staging, backup: backup,
                             launcherScript: #"[[ "$1" == -n && "$3" == --args && "$4" == --background ]]"#) == 0)
        #expect(!exists(backup))
    }
}
