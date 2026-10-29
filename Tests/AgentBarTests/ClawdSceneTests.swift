import Cocoa
import Testing
@testable import AgentBar

/// Clawd's scenes: which one a session earns, that each plays whole, and that
/// the art itself is drawable.
@Suite struct ClawdSceneTests {
    private func session(_ state: String, label: String, activity: [String] = [],
                         ts: TimeInterval = 1_000) throws -> Session {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawd-scene-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let row: [String: Any] = ["agent": "claude", "state": state, "label": label,
                                  "activity": activity, "ts": ts, "started": true]
        try JSONSerialization.data(withJSONObject: row).write(to: url)
        return try #require(Session(fileURL: url))
    }

    /// A subagent failing makes Clawd sad once, on the count growing — never on
    /// a row's first sighting, which is history.
    @Test func aFailedSubagentIsNoticedOnce() throws {
        var s = try session("tool", label: "Delegating")
        var seen: [String: Int] = [:]
        s.failedSubagents = 1
        #expect(!MascotDriver.subagentFailed(s, seen: &seen))
        #expect(!MascotDriver.subagentFailed(s, seen: &seen))
        s.failedSubagents = 2
        #expect(MascotDriver.subagentFailed(s, seen: &seen))
        #expect(!MascotDriver.subagentFailed(s, seen: &seen))
    }

    @Test func aToolShowsWhatItDoes() throws {
        let cases: [(String, ClawdScene)] = [
            ("Reading", .read), ("Searching", .search), ("Editing", .type), ("Writing", .type),
            ("Running command", .hammer), ("Searching web", .web), ("Browsing web", .web),
            ("Delegating", .delegate), ("Running tests", .test),
        ]
        for (label, scene) in cases {
            #expect(ClawdScene.scene(for: try session("tool", label: label), now: 1_000) == scene)
        }
        // A tool AgentBar has no picture for walks rather than pretending.
        #expect(ClawdScene.scene(for: try session("tool", label: "Using tool"), now: 1_000) == .walk)
    }

    @Test func thinkingHoldsTheLastToolForAWhile() throws {
        let after = try session("thinking", label: "Thinking…", activity: ["Reading", "Running command"])
        #expect(ClawdScene.scene(for: after, now: 1_000 + 2) == .hammer)
        #expect(ClawdScene.scene(for: after, now: 1_000 + ClawdScene.lingering) == .think)
        // A turn that has not touched a tool yet is thinking from the start.
        let fresh = try session("thinking", label: "Thinking…")
        #expect(ClawdScene.scene(for: fresh, now: 1_000) == .think)
    }

    @Test func compactingWinsOverEverything() throws {
        let s = try session("thinking", label: Session.compactingLabel, activity: ["Editing"])
        #expect(ClawdScene.scene(for: s, now: 1_000) == .compact)
    }

    /// update.js names the tools; a word added there without a scene here would
    /// quietly fall back to the walk.
    @Test func everyToolTheHookNamesHasAScene() throws {
        let hook = try String(contentsOfFile: "Scripts/hooks/claude/update.js", encoding: .utf8)
        let table = try #require(hook.range(of: "const TOOL_LABELS = {")
            .flatMap { start in hook[start.upperBound...].range(of: "};").map { hook[start.upperBound..<$0.lowerBound] } })
        let body = String(table)
        let pattern = try NSRegularExpression(pattern: #":\s*"([^"]+)""#)
        let labels = Set(pattern.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap {
            Range($0.range(at: 1), in: body).map { String(body[$0]) }
        })
        #expect(labels.count > 5)
        for label in labels {
            #expect(ClawdScene.scene(forTool: label) != nil, "no scene for \(label)")
        }
    }

    @Test func everyPoseIsDrawable() {
        // The 1.64 poses are drawn, not borrowed.
        #expect([ClawdScene.test, .sweat, .sad].allSatisfy { $0.reel != nil })
        for scene in ClawdScene.allCases {
            guard let reel = scene.reel else { continue }
            #expect(!reel.rhythm.isEmpty)
            #expect(reel.rhythm.allSatisfy { reel.poses.indices.contains($0) }, "\(scene)")
            // Every pose is played at least once.
            #expect(Set(reel.rhythm) == Set(reel.poses.indices), "\(scene)")
            for pose in reel.poses {
                let lines = pose.split(separator: "\n")
                #expect(lines.count == ClawdSceneArt.rows, "\(scene)")
                #expect(lines.allSatisfy { $0.count == ClawdSceneArt.columns }, "\(scene)")
                #expect(pose.allSatisfy { $0 == "\n" || $0 == "." || ClawdSceneArt.palette[$0] != nil },
                        "\(scene)")
            }
        }
    }

    @Test func heFallsAsleepOnlyAfterALongQuiet() {
        #expect(!ClawdScene.asleep(lastBusy: 1_000, now: 1_000 + ClawdScene.sleepsAfter - 1))
        #expect(ClawdScene.asleep(lastBusy: 1_000, now: 1_000 + ClawdScene.sleepsAfter))
    }

    /// Waiting and sleeping come from the state, never from a tool's label.
    @Test func noToolPutsHimToSleepOrRaisesHisHand() throws {
        for state in ["tool", "thinking"] {
            for label in ["Reading", "Using tool", "Thinking…", ""] {
                let scene = ClawdScene.scene(for: try session(state, label: label), now: 1_000)
                #expect(![.approve, .ask, .sleep].contains(scene))
            }
        }
    }

    /// The menu bar shows sleep as one still picture, so it has to exist, and it is
    /// one of the loop's own frames — the island breathes from that same loop.
    @Test @MainActor func sleepHasAStillPictureInBothModes() throws {
        let sprite = IconRenderer.shared.sprite(for: Agent.byID("claude"))
        let loop = try #require(sprite.scenes[.sleep])
        let still = try #require(loop.still)
        #expect(loop.color.contains { $0 === still.color })
        #expect(loop.template.contains { $0 === still.template })
        #expect(still.template.isTemplate)
    }

    /// With a hand up his eyes move too (to look at the session that asked), so
    /// they have to be findable on every raised-hand frame; and sad needs a still.
    @Test @MainActor func theRaisedHandHasEyesAndSadHasAStill() throws {
        let sprite = IconRenderer.shared.sprite(for: Agent.byID("claude"))
        for scene in [ClawdScene.approve, .ask] {
            let loop = try #require(sprite.scenes[scene])
            for frame in loop.color {
                #expect(MascotEyes.find(in: frame) != nil, "\(scene)")
            }
        }
        let sad = try #require(sprite.scenes[.sad]?.still)
        #expect(sad.template.isTemplate)
    }

    @Test func theBackpackFillsWithTheContext() throws {
        let sprite = IconRenderer.shared.sprite(for: Agent.byID("claude"))
        let resting = sprite.restingColor
        #expect(IslandMascot.backpack(on: resting, level: .hidden) === resting)
        let packed = [ContextGauge.Level.notice, .high, .critical].map {
            IslandMascot.backpack(on: resting, level: $0).tiffRepresentation
        }
        #expect(Set(packed.compactMap { $0 }).count == 3)
        #expect(IslandMascot.backpack(on: sprite.restingTemplate, level: .high).isTemplate)
    }

    @Test func aReelCutsOnlyAtTheEndOfItsLoop() {
        let a = (0..<3).map { _ in NSImage(size: NSSize(width: 1, height: 1)) }
        let b = (0..<2).map { _ in NSImage(size: NSSize(width: 1, height: 1)) }
        var wanted = a
        var reel = MascotReel(key: "k", frames: a, next: { wanted })
        #expect(reel.current === a[0])
        wanted = b                               // the session moved on mid-loop…
        #expect(reel.advance() === a[1])         // …and the loop on screen finishes
        #expect(reel.advance() === a[2])
        #expect(reel.advance() === b[0])         // before the cut
        #expect(reel.advance() === b[1])
        // A plain loop just goes round.
        var plain = MascotReel(key: "p", frames: a)
        _ = plain.advance(); _ = plain.advance()
        #expect(plain.advance() === a[0])
    }
}
