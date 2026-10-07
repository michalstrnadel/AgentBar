import AppKit
import Testing
@testable import AgentBar

/// Where the island's window shows up: every Space and over fullscreen apps, but
/// not over Mission Control, where it took the hover and animated over the zoomed-out
/// desktop.
@MainActor
@Suite struct IslandPanelTests {
    @Test func missionControlHidesTheIsland() {
        let b = IslandPanel().collectionBehavior
        #expect(b.contains(.transient))
        #expect(!b.contains(.stationary))
        #expect(b.contains(.canJoinAllSpaces) && b.contains(.fullScreenAuxiliary))
    }
}
