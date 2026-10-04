import AppKit
import Testing
@testable import AgentBar

/// Drawing the report, not running it. A row with a repair button used to pin its
/// width to the list before it was in the list — AppKit raises on a constraint
/// between views with no common ancestor, and the exception took the whole report
/// (and, outside a debugger, the window) with it.
@MainActor
@Suite struct DiagnosticsViewTests {
    @Test func aRowWithARepairButtonIsDrawn() {
        let view = DiagnosticsView(frame: NSRect(x: 0, y: 0, width: 470, height: 300))
        let checks = [
            Diagnostics.Check(id: "a", title: "Hooks are wired", status: .fail,
                              detail: "Not in settings.json.", fix: "Re-install them.",
                              repair: .reinstallHooks),
            Diagnostics.Check(id: "b", title: "Folders", status: .warn, detail: "Missing.",
                              fix: "Create them.", repair: .makeDirectories),
            Diagnostics.Check(id: "c", title: "Node", status: .warn, detail: "Old.", fix: "Update it."),
        ]
        view.apply(checks)
        #expect(view.rows.arrangedSubviews.count == 3)
        view.layoutSubtreeIfNeeded()
        // Redrawn over itself, as a refresh does: the old rows and their constraints go.
        view.apply(checks)
        #expect(view.rows.arrangedSubviews.count == 3)
    }
}
