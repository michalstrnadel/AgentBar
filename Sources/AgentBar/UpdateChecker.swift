import Cocoa

/// In-app updates from GitHub Releases — no Sparkle, no windows, no daemons.
/// A quiet daily check plus a "Check for Updates…" menu row; installing swaps the
/// app bundle in place and relaunches. All state surfaces as that single menu row.
final class UpdateChecker {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)     // newer version, e.g. "1.7.0"
        case downloading(String)
        case failed(String)        // short, user-facing reason
    }

    static let shared = UpdateChecker()
    private(set) var status: Status = .idle
    /// Fired on the main queue whenever `status` changes (menu refresh hook).
    var onChange: (() -> Void)?

    private static let repo = "michalstrnadel/AgentBar"
    private var zipURL: URL?
    private var timer: Timer?

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
        case .checking, .downloading: return
        case .available: if !manual { return }   // keep the offer visible
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
                    // Silent when automatic: a laptop that's offline isn't an error.
                    self.setStatus(manual ? .failed("Update check failed") : .idle)
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                if Self.isNewer(latest, than: self.currentVersion) {
                    let assets = o["assets"] as? [[String: Any]] ?? []
                    let url = assets.first { ($0["name"] as? String) == "AgentBar.app.zip" }
                        .flatMap { $0["browser_download_url"] as? String }
                        .flatMap(URL.init(string:))
                    self.zipURL = url ?? URL(string:
                        "https://github.com/\(Self.repo)/releases/download/v\(latest)/AgentBar.app.zip")
                    self.setStatus(.available(latest))
                } else {
                    self.setStatus(manual ? .upToDate : .idle)
                }
            }
        }.resume()
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

    func installAvailable() {
        guard case .available(let v) = status, let zip = zipURL else { return }
        setStatus(.downloading(v))
        URLSession.shared.downloadTask(with: zip) { [weak self] tmp, _, err in
            guard let self else { return }
            guard let tmp, err == nil else {
                DispatchQueue.main.async { self.setStatus(.failed("Download failed")) }
                return
            }
            do {
                let staged = try self.stage(downloaded: tmp, expecting: v)
                DispatchQueue.main.async {
                    do { try self.swapAndRelaunch(with: staged) }
                    catch {
                        NSLog("AgentBar update: swap failed: \(error)")
                        self.setStatus(.failed("Install failed"))
                    }
                }
            } catch {
                NSLog("AgentBar update: stage failed: \(error)")
                DispatchQueue.main.async { self.setStatus(.failed("Install failed")) }
            }
        }.resume()
    }

    /// Unzip into a private temp dir, verify it really is the promised version,
    /// strip quarantine. Returns the staged .app URL.
    private func stage(downloaded: URL, expecting version: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("agentbar-update-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
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
        return app
    }

    /// Move the running bundle aside, move the new one into its place, relaunch.
    /// On any failure the old bundle is restored — the app never ends up missing.
    private func swapAndRelaunch(with staged: URL) throws {
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
        NSLog("AgentBar update: installed \(currentVersion) → \(current.path), relaunching")
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/bash")
        relaunch.arguments = ["-c", "sleep 0.6; /usr/bin/open -n \"\(current.path)\""]
        try relaunch.run()
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func setStatus(_ s: Status) {
        guard s != status else { return }
        status = s
        onChange?()
    }

    @discardableResult
    private func run(_ tool: String, _ args: String...) throws -> Int32 {
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
