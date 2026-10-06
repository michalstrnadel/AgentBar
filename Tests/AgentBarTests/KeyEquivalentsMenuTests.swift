import AppKit
import Testing
@testable import AgentBar

/// Text fields in an accessory app learn their shortcuts from the main menu. These
/// are the ones a person reaches for in the Launcher and the token field.
@MainActor
@Suite struct KeyEquivalentsMenuTests {
    @Test func theEditShortcutsAreThereAndQuitIsNot() throws {
        _ = NSApplication.shared
        KeyEquivalentsMenu.install()
        let items = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
        let keys = Set(items.filter { $0.keyEquivalentModifierMask == .command }.map(\.keyEquivalent))
        #expect(keys.isSuperset(of: ["x", "c", "v", "a", "z", "w"]))
        #expect(!keys.contains("q"))
        #expect(items.contains { $0.action == #selector(NSText.paste(_:)) })
    }
}
