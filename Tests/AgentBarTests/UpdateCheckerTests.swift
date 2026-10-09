import Foundation
import Security
import Testing
@testable import AgentBar

/// The updater installs without a click, so what decides *when* — and whether a
/// bundle is fit to install at all — has to be provable without a network, a real
/// bundle or /Applications. Everything outside the process is a fake here: the
/// download hands back a temp file, staging builds a throwaway `.app`, the install
/// only records that it was asked.
@Suite struct UpdateCheckerTests {
    private let root: URL
    private let fm = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbar-update-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// The fakes and what they saw.
    final class Rig {
        var downloads = 0
        var downloadFails = false
        var verifyReason: String?
        var supported = true
        var installed: [URL] = []
        var idle: TimeInterval = 0
        var now = Date(timeIntervalSince1970: 1_000_000)
        var statuses: [UpdateChecker.Status] = []
        let defaults: UserDefaults
        let root: URL

        init(root: URL) throws {
            self.root = root
            defaults = try #require(UserDefaults(suiteName: "agentbar-update-\(UUID().uuidString)"))
        }

        func checker() -> UpdateChecker {
            let deps = UpdateChecker.Dependencies(
                download: { [unowned self] _, done in
                    self.downloads += 1
                    if self.downloadFails { done(nil, URLError(.notConnectedToInternet)); return }
                    let zip = self.root.appendingPathComponent("dl-\(UUID().uuidString).zip")
                    FileManager.default.createFile(atPath: zip.path, contents: Data())
                    done(zip, nil)
                },
                stage: { [unowned self] _, version in try self.makeApp(version: version) },
                verify: { [unowned self] _ in self.verifyReason },
                autoInstallSupported: { [unowned self] in self.supported },
                install: { [unowned self] app in self.installed.append(app) },
                idleSeconds: { [unowned self] in self.idle },
                now: { [unowned self] in self.now },
                main: { $0() },
                defaults: defaults)
            let c = UpdateChecker(deps)
            c.onChange = { [unowned self, unowned c] in self.statuses.append(c.status) }
            return c
        }

        /// A staged bundle as `stage` leaves one: `<staging dir>/AgentBar.app`.
        func makeApp(version: String) throws -> URL {
            let app = root.appendingPathComponent("staging-\(UUID().uuidString)/AgentBar.app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleShortVersionString": version,
                                        "CFBundleIdentifier": "com.agentbar.test"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            return app
        }
    }

    private static let newer = "999.0.0"
    private let zip = URL(string: "https://example.invalid/AgentBar.app.zip")!

    // MARK: - The decision

    @Test(arguments: [0, 1], [0, 2])
    func mayInstallOnlyWhenNothingWaits(pending: Int, waiting: Int) {
        let quiet = pending == 0 && waiting == 0
        #expect(UpdateChecker.mayInstallNow(pendingRequests: pending, waitingSessions: waiting,
                                            idleSeconds: 600, autoUpdate: true, ready: true) == quiet)
    }

    @Test(arguments: [(0.0, false), (299.0, false), (300.0, true), (3600.0, true)])
    func mayInstallOnlyAfterFiveIdleMinutes(idle: TimeInterval, expected: Bool) {
        #expect(UpdateChecker.mayInstallNow(pendingRequests: 0, waitingSessions: 0,
                                            idleSeconds: idle, autoUpdate: true, ready: true) == expected)
    }

    @Test(arguments: [(true, true, true), (false, true, false), (true, false, false), (false, false, false)])
    func mayInstallNeedsThePreferenceAndAStagedBundle(auto: Bool, ready: Bool, expected: Bool) {
        #expect(UpdateChecker.mayInstallNow(pendingRequests: 0, waitingSessions: 0,
                                            idleSeconds: 600, autoUpdate: auto, ready: ready) == expected)
    }

    @Test func adHocAndUnsignedCopiesNeverInstallByThemselves() {
        #expect(!UpdateChecker.autoInstallSupported(running: .adHoc))
        #expect(!UpdateChecker.autoInstallSupported(running: .unsigned))
    }

    @Test func autoUpdateIsOnUntilSwitchedOff() throws {
        let rig = try Rig(root: root)
        let c = rig.checker()
        #expect(c.autoUpdate)
        c.autoUpdate = false
        #expect(!c.autoUpdate)
        #expect(rig.defaults.object(forKey: "autoUpdate") as? Bool == false)
    }

    // MARK: - Transitions

    @Test func newerVersionIsStagedThenWaitsForQuiet() throws {
        let rig = try Rig(root: root)
        let c = rig.checker()
        c.found(latest: Self.newer, zip: zip, manual: false)

        #expect(rig.statuses == [.available(Self.newer), .downloading(Self.newer), .ready(Self.newer)])
        let staged = try #require(c.staged)
        #expect(fm.fileExists(atPath: staged.path))
        #expect(rig.installed.isEmpty)
        #expect(rig.defaults.string(forKey: "updateStagedVersion") == Self.newer)
    }

    @Test func quietTickInstallsOnlyAtAQuietMoment() throws {
        let rig = try Rig(root: root)
        let c = rig.checker()
        c.found(latest: Self.newer, zip: zip, manual: false)

        // Nobody said what is waiting: unknown is never quiet.
        rig.idle = 600
        c.quietTick()
        #expect(rig.installed.isEmpty)

        var pending = 1
        c.pendingRequests = { pending }
        c.waitingSessions = { 0 }
        c.quietTick()
        #expect(rig.installed.isEmpty)

        pending = 0
        rig.idle = 120
        c.quietTick()
        #expect(rig.installed.isEmpty)

        rig.idle = 301
        let staged = try #require(c.staged)
        c.quietTick()
        #expect(rig.installed == [staged])
        // The record is gone before the swap, so a relaunch cannot install twice.
        #expect(rig.defaults.string(forKey: "updateStagedPath") == nil)
        #expect(rig.defaults.string(forKey: "updateInstallAttempt") == Self.newer)
    }

    @Test func switchedOffItOnlyOffers() throws {
        let rig = try Rig(root: root)
        let c = rig.checker()
        c.autoUpdate = false
        c.found(latest: Self.newer, zip: zip, manual: false)
        #expect(c.status == .available(Self.newer))
        #expect(rig.downloads == 0)

        // Switching it back on picks the waiting offer up.
        c.autoUpdate = true
        #expect(c.status == .ready(Self.newer))
    }

    @Test func adHocBuildOnlyOffersButAClickStillInstalls() throws {
        let rig = try Rig(root: root)
        rig.supported = false
        let c = rig.checker()
        c.found(latest: Self.newer, zip: zip, manual: false)
        #expect(c.status == .available(Self.newer))
        #expect(rig.downloads == 0)

        c.installAvailable()
        #expect(rig.downloads == 1)
        #expect(rig.installed.count == 1)
    }

    @Test func readyRowRelaunchesOnAClick() throws {
        let rig = try Rig(root: root)
        let c = rig.checker()
        c.found(latest: Self.newer, zip: zip, manual: false)
        c.installAvailable()   // nothing quiet about it; the person asked
        #expect(rig.installed.count == 1)
    }

    @Test func unverifiedBundleIsRemovedAndRetriedOnlyNextDay() throws {
        let rig = try Rig(root: root)
        rig.verifyReason = "wrong certificate"
        let c = rig.checker()
        c.found(latest: Self.newer, zip: zip, manual: false)

        #expect(c.status == .failed("Update could not be verified"))
        #expect(c.staged == nil)
        let leftovers = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("staging-") }
        #expect(leftovers.isEmpty)
        #expect(rig.installed.isEmpty)

        // Menu closed, the next timer check finds the same release: no second try today.
        c.clearTransient()
        rig.now += 3600
        c.found(latest: Self.newer, zip: zip, manual: false)
        #expect(c.status == .available(Self.newer))
        #expect(rig.downloads == 1)

        // The daily tick a day later tries once more.
        rig.now += 23 * 3600
        c.check(manual: false)   // `.available` short-circuits to the retry, no network
        #expect(rig.downloads == 2)
        #expect(c.status == .failed("Update could not be verified"))
    }

    @Test func failedDownloadDoesNotLoop() throws {
        let rig = try Rig(root: root)
        rig.downloadFails = true
        let c = rig.checker()
        c.found(latest: Self.newer, zip: zip, manual: false)
        #expect(c.status == .failed("Download failed"))
        c.clearTransient()
        c.found(latest: Self.newer, zip: zip, manual: false)
        c.check(manual: false)
        #expect(rig.downloads == 1)
    }

    // MARK: - Launch

    private func persistStaged(_ rig: Rig, version: String) throws -> URL {
        let app = try rig.makeApp(version: version)
        rig.defaults.set(app.path, forKey: "updateStagedPath")
        rig.defaults.set(version, forKey: "updateStagedVersion")
        return app
    }

    @Test func stagedBeforeQuitInstallsAtLaunch() throws {
        let rig = try Rig(root: root)
        let app = try persistStaged(rig, version: Self.newer)
        let c = rig.checker()
        #expect(c.resumeAtLaunch(pendingRequests: { 0 }, waitingSessions: { 0 }))
        #expect(rig.installed.map(\.path) == [app.path])
    }

    @Test func launchWithSomethingWaitingDefersToTheQuietTimer() throws {
        let rig = try Rig(root: root)
        _ = try persistStaged(rig, version: Self.newer)
        let c = rig.checker()
        #expect(!c.resumeAtLaunch(pendingRequests: { 1 }, waitingSessions: { 0 }))
        #expect(c.status == .ready(Self.newer))
        #expect(rig.installed.isEmpty)
    }

    /// The record says one version, the bundle on disk another: whatever sits at
    /// that path now is not what was verified, so it is dropped, not installed.
    @Test func launchForgetsAStagedBundleThatIsNotWhatWasRecorded() throws {
        let rig = try Rig(root: root)
        let app = try rig.makeApp(version: "998.0.0")
        rig.defaults.set(app.path, forKey: "updateStagedPath")
        rig.defaults.set(Self.newer, forKey: "updateStagedVersion")
        let c = rig.checker()
        #expect(!c.resumeAtLaunch(pendingRequests: { 0 }, waitingSessions: { 0 }))
        #expect(c.status == .idle)
        #expect(rig.installed.isEmpty)
        #expect(!fm.fileExists(atPath: app.path))
        #expect(rig.defaults.string(forKey: "updateStagedPath") == nil)
    }

    @Test func launchForgetsARecordWhoseBundleIsGone() throws {
        let rig = try Rig(root: root)
        rig.defaults.set(root.appendingPathComponent("swept/AgentBar.app").path, forKey: "updateStagedPath")
        rig.defaults.set(Self.newer, forKey: "updateStagedVersion")
        let c = rig.checker()
        #expect(!c.resumeAtLaunch(pendingRequests: { 0 }, waitingSessions: { 0 }))
        #expect(c.status == .idle)
        #expect(rig.defaults.string(forKey: "updateStagedVersion") == nil)
    }

    /// The relaunch script put the old bundle back: that counts as a failure, so
    /// the timer does not download the same release again the same day.
    @Test func anInstallThatDidNotStartWaitsADay() throws {
        let rig = try Rig(root: root)
        rig.defaults.set(Self.newer, forKey: "updateInstallAttempt")
        let c = rig.checker()
        #expect(!c.resumeAtLaunch(pendingRequests: { 0 }, waitingSessions: { 0 }))
        #expect(rig.defaults.string(forKey: "updateInstallAttempt") == nil)
        c.found(latest: Self.newer, zip: zip, manual: false)
        #expect(rig.downloads == 0)
        #expect(c.status == .available(Self.newer))
    }

    // MARK: - Signatures

    /// A throwaway bundle around a copy of /usr/bin/true, signed ad-hoc.
    private func adHocApp(_ name: String, extra: String? = nil) throws -> URL {
        let app = root.appendingPathComponent("\(name).app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: macos.appendingPathComponent("T").path)
        let plist: [String: Any] = ["CFBundleExecutable": "T",
                                    "CFBundleIdentifier": "com.agentbar.test",
                                    "CFBundleShortVersionString": "1.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if let extra {
            let res = app.appendingPathComponent("Contents/Resources")
            try fm.createDirectory(at: res, withIntermediateDirectories: true)
            try extra.write(to: res.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "-s", "-", app.path]
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0)
        return app
    }

    private func designatedRequirement(_ app: URL) throws -> SecRequirement {
        var code: SecStaticCode?
        try #require(SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess)
        var req: SecRequirement?
        try #require(SecCodeCopyDesignatedRequirement(try #require(code), [], &req) == errSecSuccess)
        return try #require(req)
    }

    @Test func adHocRunningCopyIsRecognisedAndDisablesAutoInstall() throws {
        let app = try adHocApp("Running")
        let running = UpdateSignature.running(app)
        #expect(running == .adHoc)
        #expect(!UpdateChecker.autoInstallSupported(running: running))
    }

    @Test func onlyABundleThatSatisfiesTheRequirementPasses() throws {
        let a = try adHocApp("A")
        let b = try adHocApp("B", extra: "something else")
        let req = try designatedRequirement(a)
        #expect(UpdateSignature.check(a, against: req) == nil)
        #expect(UpdateSignature.check(b, against: req) != nil)

        // A release's requirement names a certificate; an ad-hoc bundle has none.
        var pinned: SecRequirement?
        try #require(SecRequirementCreateWithString(
            #"identifier "com.agentbar.test" and certificate root = H"0000000000000000000000000000000000000000""#
                as CFString, [], &pinned) == errSecSuccess)
        #expect(UpdateSignature.check(a, against: try #require(pinned)) != nil)
    }
}

/// When an automatic check is due. A day on a `Timer` stopped while the Mac slept,
/// and a laptop asleep every night ran a day of releases behind.
@Suite struct UpdateCadenceTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func neverCheckedIsDue() {
        #expect(UpdateChecker.isDue(lastCheck: nil, now: t0))
    }

    @Test func dueOnTheWallClockAfterFourHours() {
        #expect(!UpdateChecker.isDue(lastCheck: t0, now: t0.addingTimeInterval(3 * 3600)))
        #expect(UpdateChecker.isDue(lastCheck: t0, now: t0.addingTimeInterval(UpdateChecker.checkEvery)))
        // A night asleep counts: the wall clock moved even though no timer ran.
        #expect(UpdateChecker.isDue(lastCheck: t0, now: t0.addingTimeInterval(10 * 3600)))
    }

    @Test func aClockThatWentBackwardsDoesNotHoldChecksOff() {
        #expect(UpdateChecker.isDue(lastCheck: t0, now: t0.addingTimeInterval(-60)))
    }
}
