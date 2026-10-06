import AppKit

/// Secondary text on the island's black. The quietest line the island draws still
/// has to read: white at 30–38 % came to about 3:1, under the 4.5:1 small text
/// needs, and nothing listened to Increase Contrast. 55 % is about 6:1; with
/// Increase Contrast on it is 75 %.
enum IslandInk {
    static var quiet: NSColor {
        NSColor.white.withAlphaComponent(
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.75 : 0.55)
    }
}
