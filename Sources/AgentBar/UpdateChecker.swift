import Cocoa

/// In-app updates from GitHub Releases — no Sparkle, no windows, no daemons.
/// A quiet daily check plus a "Check for Updates…" menu row. With **Install updates
/// automatically** on (the default), a newer release is downloaded, checked and staged
/// in the background, and installed at the first quiet moment: nothing waiting on the
/// human, and nobody at the keyboard for five minutes. Installing swaps the app bundle
/// in place and relaunches. All state surfaces as that single menu row — nothing
/// appears on screen to announce an update, before or after.
final class UpdateChecker {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)     // newer version, e.g. "1.7.0"
        case downloading(String)
        case ready(String)         // downloaded, verified, staged; waiting for a quiet moment
        case failed(String)        // short, user-facing reason
    }

    /// Everything that reaches outside the process, so the state machine can be
    /// driven by tests with fakes and never touch the network, the real bundle or
    /// /Applications.
    struct Dependencies {
        var download: (URL, @escaping (URL?, Error?) -> Void) -> Void
        /// Downloaded zip + the version it must contain → the staged `.app`.
        var stage: (URL, String) throws -> URL
        /// nil when the staged bundle may be installed; otherwise the reason.
        var verify: (URL) -> String?
        /// False for an ad-hoc or unsigned running copy — see `autoInstallSupported`.
        var autoInstallSupported: () -> Bool
        /// Swap the staged bundle in and relaunch. Does not return on success.
        var install: (URL) throws -> Void
        var idleSeconds: () -> TimeInterval
        var now: () -> Date
        /// Where download completions hop back to; inline under test.
        var main: (@escaping () -> Void) -> Void
        var defaults: UserDefaults
    }

    static let shared = UpdateChecker()
    private(set) var status: Status = .idle
    /// Fired on the main queue whenever `status` changes (menu refresh hook).
    var onChange: (() -> Void)?
    /// What is waiting on the human right now, supplied by `main.swift` from the
    /// live stores. Unset means unknown, and unknown is never a quiet moment.
    var pendingRequests: (() -> Int)?
    var waitingSessions: (() -> Int)?

    private static let repo = "michalstrnadel/AgentBar"
    private var zipURL: URL?
    private var timer: Timer?
    private var quietTimer: Timer?
    /// The staged `.app` while `status` is `.ready`.
    private(set) var staged: URL?
    private let deps: Dependencies

    /// Five minutes without keyboard or mouse: long enough that a relaunch lands
    /// on nobody's half-finished click, short enough that a lunch break does it.
    static let quietIdle: TimeInterval = 5 * 60
    /// A failed automatic download or verification is tried again at most once a
    /// day. 23 hours, not 24: the daily check that retries runs 24 hours after the
    /// previous *check*, which is a little less than 24 hours after its failure.
    static let retryAfter: TimeInterval = 23 * 3600

    private static let autoUpdateKey = "autoUpdate"
    private static let lastFailureKey = "autoUpdateLastFailure"
    private static let stagedPathKey = "updateStagedPath"
    private static let stagedVersionKey = "updateStagedVersion"
    private static let attemptKey = "updateInstallAttempt"

    init(_ deps: Dependencies? = nil) {
        self.deps = deps ?? Self.live
    }

    private static var live: Dependencies {
        // The running signature never changes under a live process; ask once. A
        // sandbox (`AgentBarHome`) never installs by itself: the release it would
        // swap in relaunches through LaunchServices without the variable, and would
        // come back as the person's real AgentBar from a scratch folder.
        let supported = !AgentBarHome.isSandbox
            && Self.autoInstallSupported(running: UpdateSignature.running())
        return Dependencies(
            download: { url, done in
                URLSession.shared.downloadTask(with: url) { tmp, _, err in done(tmp, err) }.resume()
            },
            stage: { zip, version in try UpdateChecker.stage(downloaded: zip, expecting: version) },
            verify: UpdateSignature.verifyAgainstRunning,
            autoInstallSupported: { supported },
            install: { staged in try UpdateChecker.swapAndRelaunch(with: staged) },
            idleSeconds: InputIdle.seconds,
            now: Date.init,
            main: { DispatchQueue.main.async(execute: $0) },
            defaults: .standard)
    }

    /// Settings ▸ General ▸ Install updates automatically. On unless switched off.
    var autoUpdate: Bool {
        get { deps.defaults.object(forKey: Self.autoUpdateKey) as? Bool ?? true }
        set {
            deps.defaults.set(newValue, forKey: Self.autoUpdateKey)
            if newValue, case .available = status { autoStageIfAllowed() }
        }
    }

    /// Only a copy signed with a real certificate installs anything by itself. An
    /// ad-hoc dev build's designated requirement is its own cdhash, which no
    /// release can satisfy, so there is no way to tell a genuine update from any
    /// other bundle: it keeps the click-to-install row, unverified as it always was.
    static func autoInstallSupported(running: UpdateSignature.Running) -> Bool {
        if case .signed = running { return true }
        return false
    }

    /// The one decision behind an install nobody clicked. Everything must hold: a
    /// relaunch must never strand a hook that is waiting on an answer — it would
    /// fall back to the terminal prompt, but the person was looking at AgentBar's.
    static func mayInstallNow(pendingRequests: Int, waitingSessions: Int,
                              idleSeconds: TimeInterval, autoUpdate: Bool, ready: Bool) -> Bool {
        autoUpdate && ready && pendingRequests == 0 && waitingSessions == 0
            && idleSeconds >= quietIdle
    }

    var currentVersion: String {
        // Test hook: lets an E2E run pretend to be older without a special build.
        ProcessInfo.processInfo.environment["AGENTBAR_VERSION_OVERRIDE"]
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    // MARK: - Checking

    /// First check shortly after launch (network may still be waking), then daily.
    func startPeriodicChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.check(manual: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check(manual: false)
        }
    }

    func check(manual: Bool) {
        switch status {
        case .checking, .downloading, .ready: return
        case .available:
            // Keep the offer visible; the daily tick is also the once-a-day retry
            // of an automatic download that failed.
            if !manual { autoStageIfAllowed(); return }
        default: break
        }
        setStatus(manual ? .checking : status)
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            DispatchQueue.main.async {
                guard let self else { return }
                guard err == nil, let data,
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = o["tag_name"] as? String else {
                    // The UI stays vague, so the reason (offline, TLS, rate limit) has to
                    // reach Console or a bug report has nothing to go on.
                    NSLog("AgentBar update: check failed: \(err.map { "\($0)" } ?? "unreadable release payload")")
                    // Silent when automatic: a laptop that's offline isn't an error.
                    self.setStatus(manual ? .failed("Update check failed") : .idle)
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let assets = o["assets"] as? [[String: Any]] ?? []
                let url = assets.first { ($0["name"] as? String) == "AgentBar.app.zip" }
                    .flatMap { $0["browser_download_url"] as? String }
                    .flatMap(URL.init(string:))
                // Fallback built from the release's OWN tag — hardcoding a "v"
                // prefix 404'd for releases tagged without one.
                self.found(latest: latest, zip: url ?? URL(string:
                    "https://github.com/\(Self.repo)/releases/download/\(tag)/AgentBar.app.zip"),
                           manual: manual)
            }
        }.resume()
    }

    /// What a check learned. Split from the request so tests can drive it.
    func found(latest: String, zip: URL?, manual: Bool) {
        guard Self.isNewer(latest, than: currentVersion) else {
            setStatus(manual ? .upToDate : .idle)
            return
        }
        zipURL = zip
        setStatus(.available(latest))
        // A click on "Check for Updates…" is the person asking, so it is not held
        // to the once-a-day retry; the timer is.
        if !manual {
            autoStageIfAllowed()
        } else if autoUpdate && deps.autoInstallSupported() {
            stage(latest, auto: true)
        }
    }

    /// Start the background download for an `.available` version, if the
    /// preference, the running signature and the retry budget all allow it.
    private func autoStageIfAllowed() {
        guard case .available(let v) = status, autoUpdate, deps.autoInstallSupported() else { return }
        if let last = deps.defaults.object(forKey: Self.lastFailureKey) as? Date,
           deps.now().timeIntervalSince(last) < Self.retryAfter { return }
        stage(v, auto: true)
    }

    /// "Up to date" / "failed" are moment-in-time answers; forget them once the menu
    /// closes so the row is a fresh "Check for Updates…" next open.
    func clearTransient() {
        if status == .upToDate { setStatus(.idle) }
        if case .failed = status { setStatus(.idle) }
    }

    /// Numeric semver compare, tolerant of stray suffixes ("1.6.0-beta" → 1.6.0).
    static func isNewer(_ a: String, than b: String) -> Bool {
        func nums(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = nums(a), y = nums(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - Installing

    /// The menu row's click: "Install & Relaunch" on `.available`, "Relaunch now"
    /// on `.ready`. Either way it installs immediately, quiet or not.
    func installAvailable() {
        switch status {
        case .available(let v): stage(v, auto: false)
        case .ready: installStaged()
        default: break
        }
    }

    /// Download, stage and verify; then wait for a quiet moment (`auto`) or install
    /// straight away (a click).
    private func stage(_ v: String, auto: Bool) {
        guard let zip = zipURL else { return }
        setStatus(.downloading(v))
        deps.download(zip) { [weak self] tmp, err in
            guard let self else { return }
            guard let tmp, err == nil else {
                NSLog("AgentBar update: download failed: \(err.map { "\($0)" } ?? "no file on disk")")
                self.deps.main { self.fail("Download failed") }
                return
            }
            // Still on the download's own queue: unzipping a bundle does not
            // belong on the main thread.
            let app: URL
            do { app = try self.deps.stage(tmp, v) } catch {
                NSLog("AgentBar update: stage failed: \(error)")
                self.deps.main { self.fail("Install failed") }
                return
            }
            if let reason = self.deps.verify(app) {
                NSLog("AgentBar update: \(v) rejected: \(reason)")
                try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
                self.deps.main { self.fail("Update could not be verified") }
                return
            }
            self.deps.main {
                self.staged = app
                self.deps.defaults.set(app.path, forKey: Self.stagedPathKey)
                self.deps.defaults.set(v, forKey: Self.stagedVersionKey)
                self.setStatus(.ready(v))
                if auto { self.startQuietWatch() } else { self.installStaged() }
            }
        }
    }

    /// Every failure is recorded, so the timer does not try again within the day
    /// and a release that will not verify cannot become a loop.
    private func fail(_ reason: String) {
        deps.defaults.set(deps.now(), forKey: Self.lastFailureKey)
        setStatus(.failed(reason))
    }

    /// Checked once a minute, and only while an update is staged: there is
    /// nothing to decide otherwise, so nothing runs.
    private func startQuietWatch() {
        quietTimer?.invalidate()
        quietTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.quietTick()
        }
    }

    /// One look at whether now is the moment. Internal so tests can call it
    /// instead of waiting on the timer.
    func quietTick() {
        guard case .ready(let v) = status, staged != nil else {
            quietTimer?.invalidate()
            quietTimer = nil
            return
        }
        let idle = deps.idleSeconds()
        guard Self.mayInstallNow(pendingRequests: pendingRequests?() ?? 1,
                                 waitingSessions: waitingSessions?() ?? 1,
                                 idleSeconds: idle,
                                 autoUpdate: autoUpdate && deps.autoInstallSupported(),
                                 ready: true) else { return }
        NSLog("AgentBar update: nothing waiting and idle \(Int(idle))s, installing \(v) automatically")
        installStaged()
    }

    /// The launch-time half: an update staged before the app last quit is
    /// installed now, before anything is on screen — the one moment a relaunch is
    /// invisible, so it does not wait for five idle minutes. Anything waiting on
    /// the human (read from disk; the stores have not started) still defers it to
    /// the quiet-moment timer. No network here: a fresh check would hold up the
    /// launch, and the daily check finds the next release anyway.
    /// Returns true when the app is relaunching and launch should go no further.
    func resumeAtLaunch(pendingRequests: () -> Int = RequestStore.pendingOnDisk,
                        waitingSessions: () -> Int = SessionStore.waitingOnDisk) -> Bool {
        let d = deps.defaults
        // The last install named a version this copy is not: the relaunch script
        // put the old bundle back. Count it as a failure so the timer waits a day.
        if let attempt = d.string(forKey: Self.attemptKey) {
            d.removeObject(forKey: Self.attemptKey)
            if Self.isNewer(attempt, than: currentVersion) {
                NSLog("AgentBar update: \(attempt) did not start, still on \(currentVersion)")
                d.set(deps.now(), forKey: Self.lastFailureKey)
            }
        }
        guard let path = d.string(forKey: Self.stagedPathKey),
              let version = d.string(forKey: Self.stagedVersionKey) else { return false }
        let app = URL(fileURLWithPath: path)
        let onDisk = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
        guard onDisk == version, Self.isNewer(version, than: currentVersion) else {
            // Swept from the temp dir, or overtaken by an install from elsewhere.
            forgetStaged(removing: app)
            return false
        }
        staged = app
        setStatus(.ready(version))
        guard autoUpdate, deps.autoInstallSupported(),
              pendingRequests() == 0, waitingSessions() == 0 else {
            startQuietWatch()
            return false
        }
        NSLog("AgentBar update: installing \(version), staged before the last quit")
        return installStaged()
    }

    /// Verify once more right before the swap — the staged copy sat in a temp dir
    /// since — then hand over. Returns true when the app is on its way out.
    @discardableResult
    private func installStaged() -> Bool {
        guard case .ready(let v) = status, let app = staged else { return false }
        quietTimer?.invalidate()
        quietTimer = nil
        if let reason = deps.verify(app) {
            NSLog("AgentBar update: \(v) rejected before install: \(reason)")
            forgetStaged(removing: app)
            fail("Update could not be verified")
            return false
        }
        // Forgotten before the swap: the bundle is about to move, and a relaunch
        // must never find a record pointing at it and try again.
        forgetStaged(removing: nil)
        deps.defaults.set(v, forKey: Self.attemptKey)
        do {
            try deps.install(app)
            return true
        } catch {
            NSLog("AgentBar update: swap failed: \(error)")
            deps.defaults.removeObject(forKey: Self.attemptKey)
            try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
            fail("Install failed")
            return false
        }
    }

    private func forgetStaged(removing app: URL?) {
        staged = nil
        deps.defaults.removeObject(forKey: Self.stagedPathKey)
        deps.defaults.removeObject(forKey: Self.stagedVersionKey)
        if let app { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
    }

    /// Unzip into a private temp dir, verify it really is the promised version,
    /// strip quarantine. Returns the staged .app URL.
    /// Integrity model (deliberate): GitHub TLS, the version check below, and — the
    /// part that makes installing without a click acceptable — the staged bundle's
    /// signature must satisfy the *running* app's designated requirement
    /// (`UpdateSignature`), checked once here and again right before the swap. For a
    /// release that requirement names the certificate that signed it, so only a
    /// bundle signed with the same key gets in: trust on first install, pinned from
    /// then on. A checksum in release notes would come over the same channel as the
    /// zip and add nothing. An ad-hoc dev build has no requirement worth checking
    /// and so never installs on its own. Provenance — that the zip is the CI build
    /// of a tag — is the release attestation (SECURITY.md, "Verifying a download").
    private static func stage(downloaded: URL, expecting version: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("agentbar-update-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // A rejected staging dir holds a full app bundle; it must not outlive the attempt.
        var accepted = false
        defer { if !accepted { try? fm.removeItem(at: dir) } }
        let zip = dir.appendingPathComponent("AgentBar.app.zip")
        try fm.moveItem(at: downloaded, to: zip)
        try run("/usr/bin/ditto", "-xk", zip.path, dir.path)
        let app = dir.appendingPathComponent("AgentBar.app")
        guard let staged = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String,
              staged == version else {
            throw NSError(domain: "AgentBar", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "staged bundle version mismatch"])
        }
        _ = try? run("/usr/bin/xattr", "-dr", "com.apple.quarantine", app.path)
        accepted = true
        return app
    }

    /// Move the running bundle aside, move the new one into its place, relaunch.
    /// On any failure the old bundle is restored — the app never ends up missing.
    private static func swapAndRelaunch(with staged: URL) throws {
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        let backup = fm.temporaryDirectory
            .appendingPathComponent("agentbar-backup-\(UUID().uuidString).app")
        try fm.moveItem(at: current, to: backup)
        do {
            do { try fm.moveItem(at: staged, to: current) }
            catch { try fm.copyItem(at: staged, to: current) }   // cross-volume temp
        } catch {
            try? fm.moveItem(at: backup, to: current)
            throw error
        }
        let version = Bundle(url: current)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        NSLog("AgentBar update: installed \(version) → \(current.path), relaunching")
        // Past the swap the backup is dead weight, but it belongs to the process we are
        // about to kill: the relaunch script sweeps it — and the leftover staging dir —
        // only after the new bundle has actually been opened, and puts the backup back
        // if it has not.
        let staging = staged.deletingLastPathComponent()
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/bash")
        relaunch.arguments = ["-c", UpdateInstallation.relaunchScript, "agentbar-relaunch",
                              current.path, staging.path, backup.path, "/usr/bin/open"]
        try relaunch.run()
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    /// Posted on every status change. `onChange` belongs to the menu bar item; the
    /// island's own menu listens here, because in Island-only mode it is the only
    /// place an update can be seen at all.
    static let didChange = Notification.Name("AgentBarUpdateStatusDidChange")

    private func setStatus(_ s: Status) {
        guard s != status else { return }
        status = s
        onChange?()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    @discardableResult
    private static func run(_ tool: String, _ args: String...) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "AgentBar", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool) exited \(p.terminationStatus)"])
        }
        return p.terminationStatus
    }
}
