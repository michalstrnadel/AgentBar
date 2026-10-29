import AppKit

/// A replay leaving the app: a frame as a PNG, or the clip as an MP4 or a GIF,
/// every frame from `ReplayRenderer` through `WrapExport`'s writers.
enum ReplayExport {
    typealias Shape = WrapExport.Shape

    static func frame(_ r: Replay, at t: Double, shape: Shape) -> NSBitmapImageRep? {
        ReplayRenderer.bitmap(at: t, replay: r, pixels: shape.pixels)
    }

    static func writeMP4(_ r: Replay, to url: URL, shape: Shape = .story,
                         progress: (Double) -> Void = { _ in }) throws {
        try WrapExport.writeMP4(to: url, size: shape.pixels, seconds: r.duration, progress: progress) { t, size, ctx in
            ReplayRenderer.draw(at: t, replay: r, size: size, in: ctx)
        }
    }

    /// Half size, 15 fps, no dither: flat pixels compress well and dither would
    /// only add grain to them.
    static func writeGIF(_ r: Replay, to url: URL, shape: Shape = .story,
                         progress: (Double) -> Void = { _ in }) throws {
        let size = CGSize(width: shape.pixels.width / 2, height: shape.pixels.height / 2)
        try WrapExport.writeGIF(to: url, seconds: r.duration, progress: progress) { t in
            ReplayRenderer.bitmap(at: t, replay: r, pixels: size)
        }
    }

    // MARK: - Verification

    /// Frames across the clip in both shapes, the share-safe twin, the clip as a
    /// GIF (and an MP4 with `video`), and the window, into `dir`. Offscreen.
    static func renderForVerification(to dir: URL, video: Bool) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let replay = ReplayDemo.replay(named: true)
        var ok = true
        func write(_ rep: NSBitmapImageRep?, _ name: String) {
            guard let rep, let data = WrapExport.png(rep) else { ok = false; return }
            ok = (try? data.write(to: dir.appendingPathComponent(name))) != nil && ok
        }
        let n = 8
        for i in 0..<n {
            let t = replay.duration * Double(i) / Double(n - 1) * 0.999
            write(ReplayRenderer.bitmap(at: t, replay: replay, pixels: CGSize(width: 540, height: 960)),
                  String(format: "replay-%04.1fs.png", t))
        }
        for b in replay.level.beats {
            write(ReplayRenderer.bitmap(at: (b.arrive + b.leave) / 2, replay: replay,
                                        pixels: CGSize(width: 540, height: 960)),
                  String(format: "beat-%04.1fs.png", (b.arrive + b.leave) / 2))
        }
        if let bubble = replay.level.bubbles.first {
            write(frame(replay, at: (bubble.from + bubble.to) / 2, shape: .story), "replay-story-bubble.png")
        }
        write(frame(replay, at: replay.duration * 0.55, shape: .square), "replay-square.png")
        write(frame(replay.shareSafe(), at: replay.duration * 0.55, shape: .story), "replay-shared.png")
        do {
            try writeGIF(replay, to: dir.appendingPathComponent("replay.gif"))
            if video { try writeMP4(replay, to: dir.appendingPathComponent("replay.mp4")) }
        } catch {
            FileHandle.standardError.write(Data("replay video: \(error)\n".utf8))
            ok = false
        }
        ok = WrapWindow.shared.renderReplayForVerification(replay, at: replay.duration * 0.4,
                                                           to: dir.appendingPathComponent("replay-window.png")) && ok
        return ok
    }
}

/// A made-up turn for the verification render and the tests: a bug found, a
/// test that fails, a wait on you, a fix, a pass.
enum ReplayDemo {
    static func turn(start: TimeInterval = 1_790_000_000) -> ReplayTurn {
        func tool(_ dt: TimeInterval, _ name: String, _ arg: String) -> TimelinePeek.Entry {
            .init(at: start + dt, item: .tool(name, arg))
        }
        func said(_ dt: TimeInterval, _ text: String) -> TimelinePeek.Entry {
            .init(at: start + dt, item: .said(text))
        }
        return ReplayTurn(entries: [
            said(3, "Let me look at how the hook handles a timeout."),
            tool(4, "Read", "permission.js"),
            tool(9, "Grep", "timeoutMs"),
            tool(14, "Read", "HookWiring.swift"),
            tool(16, "Read", "Session.swift"),
            said(40, "Found it: the prompt fires before the timer is cleared."),
            tool(42, "Edit", "permission.js"),
            tool(70, "Bash", "swift test --filter Permission"),
            said(98, "One test still fails; the fixture expects the old order."),
            tool(102, "Edit", "PermissionTests.swift"),
            tool(480, "Bash", "swift test"),
            tool(530, "WebFetch", "developer.apple.com"),
            said(560, "All tests pass. The hook now times out quietly."),
        ], failures: [
            ReplayLevel.Failure(at: start + 92, tests: true),
        ], prompted: start)
    }

    static func segments(start: TimeInterval = 1_790_000_000) -> [SessionTimeline.Segment] {
        [
            .init(phase: .working, start: start, end: start + 300),
            .init(phase: .waiting, start: start + 300, end: start + 430),
            .init(phase: .working, start: start + 430, end: start + 565),
        ]
    }

    static func replay(named: Bool) -> Replay {
        Replay(turn: turn(), segments: segments(), project: "agentbar", named: named)
    }
}
