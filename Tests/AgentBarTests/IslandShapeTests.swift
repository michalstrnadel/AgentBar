import CoreGraphics
import Testing
@testable import AgentBar

/// The island's outline. Points are probed in the path's own y-up coordinates:
/// `h` is the top edge, the one that meets the menu bar.
struct IslandShapeTests {
    private let corner: CGFloat = 14
    private let e = IslandShape.earWidth

    @Test func frameWidensByOneEarEachSide() {
        #expect(IslandShape.panelWidth(body: 460, ear: e) == 460 + 2 * e)
        // Off a notch there are no ears and the frame is the body.
        #expect(IslandShape.panelWidth(body: 460, ear: 0) == 460)
        #expect(IslandShape.panelWidth(body: 460, ear: -3) == 460)
    }

    /// The pill must never sprout ears — it is narrower than the notch on purpose,
    /// and anything past the notch's curve shows as horns on the real screen.
    @Test func earsGrowWithHeightFromThePillUp() {
        #expect(IslandShape.ear(full: e, height: 30, collapsedHeight: 30) == 0)
        #expect(IslandShape.ear(full: e, height: 20, collapsedHeight: 30) == 0)
        #expect(IslandShape.ear(full: e, height: 40, collapsedHeight: 30) == 5)
        #expect(IslandShape.ear(full: e, height: 200, collapsedHeight: 30) == e)
        // Off a notch the ceiling is zero, at any height.
        #expect(IslandShape.ear(full: 0, height: 200, collapsedHeight: 30) == 0)
    }

    @Test func boundsFillTheFrame() {
        let size = CGSize(width: 484, height: 120)
        for (ear, flush) in [(e, true), (0, true), (0, false), (e, false)] {
            let box = IslandShape.path(in: size, corner: corner, ear: ear, flushTop: flush)
                .boundingBoxOfPath
            #expect(abs(box.minX) < 0.01 && abs(box.minY) < 0.01)
            #expect(abs(box.width - size.width) < 0.01)
            #expect(abs(box.height - size.height) < 0.01)
        }
    }

    /// The ears flow into the top edge, and the strip beside the body under them
    /// is empty — that strip is the desktop's, to see and to click.
    @Test func earsFillTheShoulderAndLeaveTheStripEmpty() {
        let w: CGFloat = 484, h: CGFloat = 120
        let p = IslandShape.path(in: CGSize(width: w, height: h), corner: corner,
                                 ear: e, flushTop: true)
        // The body.
        #expect(p.contains(CGPoint(x: w / 2, y: h / 2)))
        // Right against the top edge, where the ear thins out into it.
        #expect(p.contains(CGPoint(x: 4, y: h - 0.2)))
        #expect(p.contains(CGPoint(x: w - 4, y: h - 0.2)))
        // The shoulder, just outside the body's side and just below the edge.
        #expect(p.contains(CGPoint(x: e - 1, y: h - 1)))
        #expect(p.contains(CGPoint(x: w - e + 1, y: h - 1)))
        // Inside the fillet's circle: hollow, which is what makes it concave.
        #expect(!p.contains(CGPoint(x: 2, y: h - e + 2)))
        #expect(!p.contains(CGPoint(x: w - 2, y: h - e + 2)))
        // The strip beside the body, all the way down.
        #expect(!p.contains(CGPoint(x: e / 2, y: h / 2)))
        #expect(!p.contains(CGPoint(x: w - e / 2, y: h / 2)))
        #expect(!p.contains(CGPoint(x: e / 2, y: 2)))
    }

    /// No ears: the shape it always was — square on top flush with the notch,
    /// round on top floating, round below either way.
    @Test func withoutEarsTheTopIsSquareOrRound() {
        let size = CGSize(width: 460, height: 120)
        let flush = IslandShape.path(in: size, corner: corner, ear: 0, flushTop: true)
        #expect(flush.contains(CGPoint(x: 0.5, y: 119.5)))
        #expect(flush.contains(CGPoint(x: 459.5, y: 119.5)))
        #expect(!flush.contains(CGPoint(x: 0.5, y: 0.5)))
        let floating = IslandShape.path(in: size, corner: corner, ear: 0, flushTop: false)
        #expect(!floating.contains(CGPoint(x: 0.5, y: 119.5)))
        #expect(!floating.contains(CGPoint(x: 459.5, y: 119.5)))
        #expect(!floating.contains(CGPoint(x: 0.5, y: 0.5)))
        #expect(floating.contains(CGPoint(x: 230, y: 119.5)))
    }

    /// A floating bar has no edge to flow into, so an ear asked for there is ignored.
    @Test func earsNeedAFlushTop() {
        let size = CGSize(width: 484, height: 120)
        let a = IslandShape.path(in: size, corner: corner, ear: e, flushTop: false)
        let b = IslandShape.path(in: size, corner: corner, ear: 0, flushTop: false)
        #expect(a == b)
    }

    /// Frames caught mid-animation, or degenerate ones, still give a closed path
    /// inside the frame rather than arcs that overlap or run outside it.
    @Test func oddSizesStayWellFormed() {
        for size in [CGSize(width: 0, height: 0), CGSize(width: 10, height: 4),
                     CGSize(width: 30, height: 200), CGSize(width: 175, height: 31)] {
            for flush in [true, false] {
                let box = IslandShape.path(in: size, corner: corner, ear: e, flushTop: flush)
                    .boundingBoxOfPath
                #expect(box.minX >= -0.01 && box.minY >= -0.01)
                #expect(box.maxX <= size.width + 0.01 && box.maxY <= size.height + 0.01)
            }
        }
    }
}
