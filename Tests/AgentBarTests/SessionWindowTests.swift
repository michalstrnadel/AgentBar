import Cocoa
import Testing
@testable import AgentBar

/// Which of an app's windows Clawd looks at when its session waits, and the gaze
/// that goes there.
struct SessionWindowTests {
    private func w(_ pid: Int32, layer: Int = 0, alpha: Double = 1,
                   _ rect: CGRect) -> SessionWindow.Window {
        .init(pid: pid, layer: layer, alpha: alpha, bounds: rect)
    }

    @Test func theTopmostNormalWindowOfTheAppIsTheOne() {
        let list = [
            w(7, CGRect(x: 0, y: 0, width: 900, height: 600)),       // another app, on top
            w(42, layer: 25, CGRect(x: 0, y: 0, width: 300, height: 300)),   // its panel
            w(42, alpha: 0, CGRect(x: 0, y: 0, width: 500, height: 500)),    // invisible
            w(42, CGRect(x: 10, y: 10, width: 40, height: 20)),      // a sliver
            w(42, CGRect(x: 100, y: 200, width: 800, height: 500)),  // the window
            w(42, CGRect(x: 0, y: 0, width: 1200, height: 800)),     // behind it
        ]
        #expect(SessionWindow.frontmost(of: 42, in: list) == CGRect(x: 100, y: 200, width: 800, height: 500))
        #expect(SessionWindow.frontmost(of: 99, in: list) == nil)
        #expect(SessionWindow.frontmost(of: 42, in: []) == nil)
    }

    @Test func aWindowServerEntryIsReadOrSkipped() throws {
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 400).dictionaryRepresentation
        let ok: [String: Any] = [kCGWindowOwnerPID as String: 42, kCGWindowLayer as String: 0,
                                 kCGWindowBounds as String: bounds, kCGWindowAlpha as String: 1.0]
        let read = try #require(SessionWindow.window(ok))
        #expect(read == w(42, CGRect(x: 1, y: 2, width: 300, height: 400)))
        var noBounds = ok
        noBounds[kCGWindowBounds as String] = nil
        #expect(SessionWindow.window(noBounds) == nil)
        var noAlpha = ok
        noAlpha[kCGWindowAlpha as String] = nil
        #expect(SessionWindow.window(noAlpha)?.alpha == 1)
    }

    /// The window server counts y down from the top of the main display; the
    /// pointer and the pill count it up from the bottom.
    @Test func theCentreIsInAppKitsSpace() {
        let c = SessionWindow.centre(of: CGRect(x: 100, y: 0, width: 200, height: 100), mainHeight: 1000)
        #expect(c == NSPoint(x: 200, y: 950))
    }

    @Test func theEyesTurnTowardTheWindowWhereverItIs() {
        typealias G = MascotPersonality.Gaze
        // Far away, below and to the left — no reach limit, unlike the pointer.
        #expect(G.toward(dx: -3000, dy: -3000, current: .ahead) == .init(dx: -1, dy: -1))
        #expect(G.toward(dx: 5000, dy: 0, current: .ahead) == .init(dx: 1, dy: 0))
        // Straight under the mark: keeps what it had.
        #expect(G.toward(dx: 1, dy: 1, current: .init(dx: 1, dy: 0)) == .init(dx: 1, dy: 0))
        // Hysteresis: a diagonal just under `engage` keeps an eye that already looks.
        let angle = asin(0.4)
        let (dx, dy) = (cos(angle) * 500, sin(angle) * 500)
        #expect(G.toward(dx: dx, dy: dy, current: .ahead) == .init(dx: 1, dy: 0))
        #expect(G.toward(dx: dx, dy: dy, current: .init(dx: 1, dy: 1)) == .init(dx: 1, dy: 1))
    }
}
