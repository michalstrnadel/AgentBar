import AppKit
import Testing
@testable import AgentBar

private func session(_ fields: [String: Any]) throws -> Session {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("s-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    var o: [String: Any] = ["agent": "claude", "state": "thinking", "started": true, "ts": 1_000,
                            "project": "AgentBar", "pid": 4242, "term_program": "iTerm.app"]
    o.merge(fields) { $1 }
    try JSONSerialization.data(withJSONObject: o).write(to: url)
    return try #require(Session(fileURL: url))
}

/// Handing a file to an agent: what is typed, and where it may be.
@Suite struct DropToAgentTests {
    @Test func pathsAreEscapedTheWayTerminalEscapesADraggedFile() {
        #expect(DropToAgent.escape("/Users/me/Screenshot 2026-10-07 at 14.02.png")
                == #"/Users/me/Screenshot\ 2026-10-07\ at\ 14.02.png"#)
        #expect(DropToAgent.escape("/tmp/it's (1) & $x.txt") == #"/tmp/it\'s\ \(1\)\ \&\ \$x.txt"#)
        #expect(DropToAgent.escape("/tmp/Snímek obrazovky.png") == #"/tmp/Snímek\ obrazovky.png"#)
    }

    /// Never a Return: a path with a line break in it is left out, and the text
    /// ends in a space so the person keeps typing.
    @Test func theTextNeverCarriesALineBreak() {
        #expect(DropToAgent.text(for: ["/a/b.png", "/a/c.png"]) == "/a/b.png /a/c.png ")
        #expect(DropToAgent.text(for: ["/a/evil\nrm -rf ~"]) == nil)
        #expect(DropToAgent.text(for: ["/a/evil\r", "/a/ok"]) == "/a/ok ")
        #expect(DropToAgent.text(for: []) == nil)
    }

    @Test func onlySessionsOnThisMacInATerminalTakeAFile() throws {
        #expect(DropToAgent.refusal(for: try session([:])) == nil)
        #expect(DropToAgent.refusal(for: try session(["entrypoint": "cloud"])) != nil)
        #expect(DropToAgent.refusal(for: try session(["entrypoint": "claude-desktop"])) != nil)
        #expect(DropToAgent.refusal(for: try session(["entrypoint": "antigravity-app"])) != nil)
        #expect(DropToAgent.refusal(for: try session(["pid": 0])) != nil)
    }

    /// Typed only where the tab can be verified, and only with the permission.
    @Test func pastingNeedsAVerifiedTabAndThePermission() throws {
        #expect(DropToAgent.canPaste(into: try session(["term_program": "iTerm.app"]), trusted: true))
        #expect(DropToAgent.canPaste(into: try session(["term_program": "Apple_Terminal"]), trusted: true))
        #expect(!DropToAgent.canPaste(into: try session(["term_program": "WarpTerminal"]), trusted: true))
        #expect(!DropToAgent.canPaste(into: try session(["term_program": "ghostty"]), trusted: true))
        #expect(!DropToAgent.canPaste(into: try session(["term_program": "iTerm.app"]), trusted: false))
    }

    @Test func anImageWithNoFileIsSavedAndOldOnesArePruned() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("drops-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pb = NSPasteboard(name: .init("agentbar-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        pb.clearContents()
        pb.setData(rep.representation(using: .png, properties: [:]), forType: .png)
        let paths = DropToAgent.paths(from: pb, dir: dir)
        #expect(paths.count == 1)
        #expect(FileManager.default.fileExists(atPath: paths[0]))
        let old = dir.appendingPathComponent("old.png")
        try Data().write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -8 * 86_400)],
                                              ofItemAtPath: old.path)
        DropToAgent.prune(dir: dir)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: paths[0]))
    }

    @Test func filesAreHandedOverAsTheirPaths() {
        let pb = NSPasteboard(name: .init("agentbar-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/a b.txt") as NSURL])
        #expect(DropToAgent.paths(from: pb) == ["/tmp/a b.txt"])
    }
}

@Suite struct ScreenshotShelfTests {
    @Test func theFolderComesFromTheScreenshotSettingsOrTheDesktop() throws {
        let suite = "agentbar-test-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(ScreenshotShelf.folder(defaults: d, home: home).path == "/Users/someone/Desktop")
        d.set(NSTemporaryDirectory(), forKey: "location")
        #expect(ScreenshotShelf.folder(defaults: d, home: home).path
                == URL(fileURLWithPath: NSTemporaryDirectory()).path)
        d.set("/nowhere/at/all", forKey: "location")
        #expect(ScreenshotShelf.folder(defaults: d, home: home).path == "/Users/someone/Desktop")
    }

    @Test func onlyARecentScreenshotIsOffered() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        func file(_ name: String, age: TimeInterval) throws -> URL {
            let u = dir.appendingPathComponent(name)
            try Data().write(to: u)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: u.path)
            return u
        }
        _ = try file("old shot.png", age: 600)
        let fresh = try file("fresh shot.png", age: 30)
        _ = try file("not a shot.png", age: 10)
        let isShot = { (u: URL) in u.lastPathComponent.contains("shot.png") && !u.lastPathComponent.hasPrefix("not") }
        #expect(ScreenshotShelf.latest(in: dir, now: now, isScreenshot: isShot)?.lastPathComponent
                == fresh.lastPathComponent)
        #expect(ScreenshotShelf.latest(in: dir, now: now.addingTimeInterval(400), isScreenshot: isShot) == nil)
    }
}

@Suite struct UsagePaceTests {
    private func samples(from used: Double, perMinute: Double, minutes: Int, now: TimeInterval) -> [UsagePace.Sample] {
        (0...minutes).map { m in
            UsagePace.Sample(t: now - Double(minutes - m) * 60, used: used + perMinute * Double(m))
        }
    }

    @Test func aSteadyPaceRunsOutWhenTheLineSays() throws {
        let now: TimeInterval = 1_000_000
        let s = samples(from: 40, perMinute: 0.5, minutes: 20, now: now)   // 30 %/h, at 50 %
        let f = try #require(UsagePace.forecast(s, used: 50, resetsAt: Date(timeIntervalSince1970: now + 4 * 3600), now: now))
        #expect(abs(f.runsOutAt.timeIntervalSince1970 - (now + 100 * 60)) < 1)
        #expect(abs(f.perHour - 30) < 0.01)
    }

    @Test func aWindowThatResetsFirstSaysNothing() {
        let now: TimeInterval = 1_000_000
        let s = samples(from: 40, perMinute: 0.5, minutes: 20, now: now)
        #expect(UsagePace.forecast(s, used: 50, resetsAt: Date(timeIntervalSince1970: now + 3600), now: now) == nil)
    }

    @Test func tooLittleOrTooFlatSaysNothing() {
        let now: TimeInterval = 1_000_000
        #expect(UsagePace.forecast(samples(from: 40, perMinute: 0.5, minutes: 5, now: now), used: 42.5,
                                   resetsAt: nil, now: now) == nil)              // 5 minutes of data
        #expect(UsagePace.forecast(samples(from: 40, perMinute: 0.005, minutes: 30, now: now), used: 40.15,
                                   resetsAt: nil, now: now) == nil)              // 0.3 %/h
        #expect(UsagePace.forecast(samples(from: 60, perMinute: -0.5, minutes: 30, now: now), used: 45,
                                   resetsAt: nil, now: now) == nil)              // going down
    }

    @Test func aResetClearsTheHistory() {
        let pace = UsagePace()
        let reset = Date().addingTimeInterval(365 * 86_400)
        for m in 0..<20 {
            pace.record([UsageCenter.Reading(provider: "Codex", text: "",
                windows: [UsageWindow(name: "5h", usedPercent: 40 + Double(m), resetsAt: reset)])],
                now: 1_000_000 + Double(m) * 60)
        }
        let w = UsageWindow(name: "5h", usedPercent: 59, resetsAt: reset)
        #expect(pace.forecast(provider: "Codex", window: w, now: 1_000_000 + 19 * 60) != nil)
        pace.record([UsageCenter.Reading(provider: "Codex", text: "",
            windows: [UsageWindow(name: "5h", usedPercent: 2, resetsAt: reset.addingTimeInterval(5 * 3600))])],
            now: 1_000_000 + 20 * 60)
        #expect(pace.forecast(provider: "Codex", window: UsageWindow(name: "5h", usedPercent: 2, resetsAt: nil),
                              now: 1_000_000 + 20 * 60) == nil)
    }
}

@Suite struct QuietWatchTests {
    @Test func aWorkingSessionSilentLongEnoughIsFlagged() throws {
        let s = try session(["ts": 1_000])
        #expect(QuietWatch.quietMinutes(s, now: 1_000 + 9 * 60, threshold: 10) == nil)
        #expect(QuietWatch.quietMinutes(s, now: 1_000 + 12 * 60, threshold: 10) == 12)
        #expect(QuietWatch.quietMinutes(s, now: 1_000 + 12 * 60, threshold: 0) == nil)
        #expect(QuietWatch.label(12) == "quiet 12m?")
        #expect(QuietWatch.label(75) == "quiet 1h 15m?")
    }

    @Test func waitingDoneCloudAndDecayedAreNeverFlagged() throws {
        for fields: [String: Any] in [["state": "permission"], ["state": "done"], ["state": "idle"],
                                      ["entrypoint": "cloud"]] {
            #expect(QuietWatch.quietMinutes(try session(fields), now: 1_000 + 3600, threshold: 10) == nil,
                    "\(fields)")
        }
        var decayed = try session([:])
        decayed.decayed = true      // set by the store, never read from the file
        #expect(QuietWatch.quietMinutes(decayed, now: 1_000 + 3600, threshold: 10) == nil)
    }
}
