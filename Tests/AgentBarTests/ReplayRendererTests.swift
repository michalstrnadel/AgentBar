import AppKit
import Testing
@testable import AgentBar

/// The replay's picture: the same moment draws the same pixels, the clip moves,
/// and the share-safe twin carries no names and no words.
@MainActor
@Suite struct ReplayRendererTests {
    private func pixels(_ rep: NSBitmapImageRep) -> Data { Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh) }

    @Test func theSameMomentDrawsTheSamePicture() throws {
        let r = ReplayDemo.replay(named: true)
        for size in [CGSize(width: 270, height: 480), CGSize(width: 300, height: 300)] {
            for t in [0.0, 2.3, r.duration * 0.5, r.duration] {
                let a = try #require(ReplayRenderer.bitmap(at: t, replay: r, pixels: size))
                let b = try #require(ReplayRenderer.bitmap(at: t, replay: r, pixels: size))
                #expect(pixels(a) == pixels(b))
            }
        }
    }

    @Test func theClipMoves() throws {
        let r = ReplayDemo.replay(named: false)
        let size = CGSize(width: 270, height: 480)
        let a = try #require(ReplayRenderer.bitmap(at: 1, replay: r, pixels: size))
        let b = try #require(ReplayRenderer.bitmap(at: r.duration * 0.6, replay: r, pixels: size))
        #expect(pixels(a) != pixels(b))
    }

    @Test func theShareSafeTwinNamesNothing() {
        let r = ReplayDemo.replay(named: true)
        #expect(r.project == "agentbar")
        #expect(!r.level.bubbles.isEmpty)
        let safe = r.shareSafe()
        #expect(safe.project.isEmpty)
        #expect(safe.level.bubbles.isEmpty)
        #expect(!safe.named)
        // A replay made without names never had them.
        #expect(Replay(turn: ReplayDemo.turn(), project: "secret", named: false).project.isEmpty)
    }

    @Test func theDemoClipFitsTheRange() {
        let d = ReplayDemo.replay(named: true).duration
        #expect(d >= ReplayLevel.minSeconds && d <= ReplayLevel.maxSeconds)
    }

    @Test func everyStationHasAProp() {
        for scene in [ClawdScene.read, .hammer, .type, .search, .web, .delegate, .walk] {
            let art = ReplayRenderer.propArt(scene)
            #expect(art.contains { ClawdSceneArt.palette[$0] != nil }, "no prop for \(scene)")
        }
    }

    @Test func captionsTellTheStory() {
        let l = ReplayDemo.replay(named: false).level
        #expect(ReplayRenderer.caption(at: 0, in: l) == "Off it goes")
        #expect(ReplayRenderer.caption(at: l.duration, in: l) == "Done")
        let pit = l.beats.first { if case .pit = $0.kind { return true }; return false }!
        #expect(ReplayRenderer.caption(at: pit.arrive + 0.01, in: l) == "Tests failed — hop")
    }
}
