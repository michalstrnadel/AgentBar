import Foundation

/// Whether the marks follow the menu bar (monochrome templates) or wear each
/// agent's own colours. One stored fact, settable from any surface's menu —
/// the status item dropdown, the island's ⋯ menu, the Appearance window —
/// persisted across launches.
enum IconColor {
    private static let key = "systemColor"

    /// Fired after a change so every live surface repaints now, not on the
    /// next poll. Owned by the app delegate, same as `Presentation.onChange`.
    static var onChange: ((Bool) -> Void)?

    static var system: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            guard newValue != system else { return }
            UserDefaults.standard.set(newValue, forKey: key)
            onChange?(newValue)
        }
    }
}
