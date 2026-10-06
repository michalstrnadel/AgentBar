import AppKit
import Testing
@testable import AgentBar

/// What VoiceOver reads for the drawn controls: the words, never the glyphs.
@MainActor
@Suite struct AccessibilityLabelTests {
    @Test func approvalButtonsAreReadWithoutTheirGlyph() {
        #expect(ApprovalButtonsRow.spoken("✓ Allow") == "Allow")
        #expect(ApprovalButtonsRow.spoken("✕ Deny") == "Deny")
        #expect(ApprovalButtonsRow.spoken("⌨ Terminal") == "Terminal")
        #expect(ApprovalButtonsRow.spoken("⧉ Claude app") == "Claude app")
        #expect(ApprovalButtonsRow.spoken("Allow") == "Allow")
    }

    @Test func aSidebarPageIsAButtonNamedAfterThePage() throws {
        final class Sink: NSObject { @objc func go(_ s: Any?) {} }
        let sink = Sink()
        let page = try #require(SettingsWindow.Page.allCases.first)
        let item = SidebarItem(page: page, target: sink, action: #selector(Sink.go(_:)))
        #expect(item.isAccessibilityElement())
        #expect(item.accessibilityRole() == .button)
        #expect(item.accessibilityLabel() == page.title)
        item.isSelected = true
        #expect(item.isAccessibilitySelected())
    }
}
