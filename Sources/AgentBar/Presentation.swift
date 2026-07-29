import Foundation

/// Which surface AgentBar shows itself on. Picked in the welcome window on first
/// launch, changeable there afterwards, persisted across launches.
enum Presentation: String, CaseIterable {
    case menuBar, island, both

    /// Menu bar until the user says otherwise: it is the surface every macOS user
    /// already understands, and the island is the one that needs explaining.
    static let fallback = Presentation.menuBar
    private static let key = "presentationMode"

    /// Fired after `current` changes, so surfaces can be added or dropped live
    /// instead of on the next launch.
    static var onChange: (() -> Void)?

    static var current: Presentation {
        get { Presentation(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? fallback }
        set {
            guard newValue != current else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            onChange?()
        }
    }

    var showsStatusItem: Bool { self != .island }
    var showsIsland: Bool { self != .menuBar }

    var title: String {
        switch self {
        case .menuBar: return "Menu bar"
        case .island:  return "Dynamic Island"
        case .both:    return "Both"
        }
    }

    var caption: String {
        switch self {
        case .menuBar: return "The mark sits in the menu bar. Click it for the full menu."
        case .island:  return "A small pill under the notch. Point at it for the sessions "
                            + "and any approval waiting on you."
        case .both:    return "Island for glancing, menu bar for the full menu."
        }
    }
}
