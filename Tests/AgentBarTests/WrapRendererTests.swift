import AppKit
import Testing
@testable import AgentBar

/// The recap's picture: one card that builds and then holds, the same moment
/// draws the same pixels, and a fact with nothing behind it gets no tile.
@MainActor
@Suite struct WrapRendererTests {
    private let wrap = WrapDemo.wrap(.today)

    private func pixels(_ rep: NSBitmapImageRep) -> Data { Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh) }

    private func colours(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<String>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 9) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 9) {
                if let c = rep.colorAt(x: x, y: y) {
                    seen.insert("\(Int(c.redComponent * 8))\(Int(c.greenComponent * 8))\(Int(c.blueComponent * 8))")
                }
            }
        }
        return seen.count
    }

    @Test func theSameMomentDrawsTheSamePicture() throws {
        let size = CGSize(width: 270, height: 480)
        for range in DayWrap.Range.allCases {
            let w = WrapDemo.wrap(range)
            for t in [0.3, 1.2, 2.0] {
                let a = try #require(WrapRenderer.bitmap(at: t, wrap: w, pixels: size))
                let b = try #require(WrapRenderer.bitmap(at: t, wrap: w, pixels: size))
                #expect(pixels(a) == pixels(b), "\(range) at \(t) is not deterministic")
            }
        }
    }

    @Test func theBuildEndsOnTheStillCard() throws {
        let size = CGSize(width: 270, height: 480)
        let end = try #require(WrapRenderer.bitmap(at: WrapRenderer.buildSeconds, wrap: wrap, pixels: size))
        let still = try #require(WrapRenderer.bitmap(at: 0, wrap: wrap, pixels: size, still: true))
        #expect(pixels(end) == pixels(still))
        // And it is built up, not there from the first frame.
        let start = try #require(WrapRenderer.bitmap(at: 0.05, wrap: wrap, pixels: size))
        #expect(pixels(start) != pixels(still))
        #expect(colours(still) > colours(start))
    }

    @Test func theCardRendersInBothShapes() throws {
        let story = try #require(WrapExport.card(wrap.shareSafe(), shape: .story))
        let square = try #require(WrapExport.card(wrap.shareSafe(), shape: .square))
        #expect(story.pixelsWide == 1080 && story.pixelsHigh == 1920)
        #expect(square.pixelsWide == 1080 && square.pixelsHigh == 1080)
        #expect(WrapExport.png(story)?.isEmpty == false)
        #expect(colours(story) >= 6)
        #expect(colours(square) >= 6)
    }

    @Test func anEmptyDayStillDrawsACard() throws {
        let empty = DayWrap.make(.today, history: [], ledger: [])
        #expect(WrapRenderer.tileFacts(empty).isEmpty)
        let rep = try #require(WrapExport.card(empty, shape: .story))
        #expect(colours(rep) >= 3)
    }

    @Test func tilesAreOnlyTheFactsThatExist() {
        let facts = WrapRenderer.tileFacts(wrap).map(\.caption)
        #expect(Array(facts.prefix(4)) == ["Top agent", "Changed", "Your answers", "Your prompts"])
        var bare = wrap
        bare.changeMeasured = 0
        bare.waits = DayWrap.Waits()
        let left = WrapRenderer.tileFacts(bare).map(\.caption)
        #expect(!left.contains("Changed") && !left.contains("Your answers"))
        #expect(left.first == "Top agent")
    }

    @Test func aSharedCardNamesNoProject() {
        let shared = WrapRenderer.tileFacts(wrap.shareSafe())
        let project = shared.first { $0.caption == "Top project" }
        #expect(project?.value == "Project A")
        #expect(project?.detail.contains("AgentBar") == false)
    }

    @Test func voiceOverReadsTheCard() {
        let spoken = WrapCardView.spoken(wrap)
        #expect(spoken.contains(wrap.persona.title))
        #expect(spoken.contains("Top agent: Claude"))
    }

    @Test func aGIFIsWritten() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wrap-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let empty = DayWrap.make(.today, history: [], ledger: [])
        try WrapExport.writeGIF(empty, to: url)
        let data = try Data(contentsOf: url)
        #expect(data.starts(with: Array("GIF8".utf8)), "\(data.prefix(6).map { $0 })")
    }
}
