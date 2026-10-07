import AppKit
import Testing
@testable import AgentBar

/// The recap's pictures: every slide draws something, the same moment draws the
/// same pixels, and a slide with nothing behind it is left out.
@MainActor
@Suite struct WrapRendererTests {
    private let wrap = WrapDemo.wrap(.today)

    private func pixels(_ rep: NSBitmapImageRep) -> Data { Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh) }

    @Test func aFullDayHasEverySlideAndEndsOnTheCard() {
        let slides = WrapRenderer.slides(for: wrap)
        #expect(slides.first == .cover)
        #expect(slides.last == .card)
        #expect(slides.contains(.time) && slides.contains(.agent) && slides.contains(.code))
        #expect(!slides.contains(.bestDay))   // a day has no best day
        #expect(WrapRenderer.slides(for: WrapDemo.wrap(.week)).contains(.bestDay))
    }

    @Test func anEmptyDayIsJustTheCover() {
        let empty = DayWrap.make(.today, history: [], ledger: [])
        #expect(WrapRenderer.slides(for: empty) == [.cover])
    }

    @Test func everySlideDrawsAndTheSameMomentDrawsTheSamePicture() throws {
        let size = CGSize(width: 270, height: 480)
        let week = WrapDemo.wrap(.week)
        for slide in WrapRenderer.slides(for: week) {
            let a = try #require(WrapRenderer.bitmap(slide, at: 1.2, wrap: week, pixels: size))
            let b = try #require(WrapRenderer.bitmap(slide, at: 1.2, wrap: week, pixels: size))
            #expect(pixels(a) == pixels(b), "\(slide) is not deterministic")
            // Not one flat colour: words and shapes were drawn on the background.
            var seen = Set<String>()
            for x in stride(from: 0, to: 270, by: 9) {
                for y in stride(from: 0, to: 480, by: 9) {
                    if let c = a.colorAt(x: x, y: y) {
                        seen.insert("\(Int(c.redComponent * 8))\(Int(c.greenComponent * 8))\(Int(c.blueComponent * 8))")
                    }
                }
            }
            #expect(seen.count >= 3, "\(slide) drew nothing")
        }
    }

    @Test func theCardRendersInBothShapes() throws {
        let story = try #require(WrapExport.card(wrap.shareSafe(), shape: .story))
        let square = try #require(WrapExport.card(wrap.shareSafe(), shape: .square))
        #expect(story.pixelsWide == 1080 && story.pixelsHigh == 1920)
        #expect(square.pixelsWide == 1080 && square.pixelsHigh == 1080)
        #expect(WrapExport.png(story)?.isEmpty == false)
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
