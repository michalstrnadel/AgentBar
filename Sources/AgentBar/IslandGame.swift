import Cocoa

/// What the island needs from a game it opens into (`IslandController+Game`):
/// a view of the island's size that runs a clock only while it is played, can be
/// paused and stopped, and says when it wants to close or wants the keys back.
/// Both games — Take a break and Bug Hunt — are one of these; the island's rules
/// for them (opened on a click, stepping aside for work) are the same.
protocol IslandGame: NSView {
    var score: Int { get }
    var onClose: (() -> Void)? { get set }
    var onWantsKeys: (() -> Void)? { get set }
    func resume()
    func pause()
    func stop()
}

/// The games on offer, in the order the picker lists them.
enum GameChoice: String, CaseIterable {
    case spaceBugs = "space"
    case bugHunt = "hunt"

    var title: String {
        switch self {
        case .spaceBugs: return "Take a break"
        case .bugHunt: return "Bug Hunt"
        }
    }

    var detail: String {
        switch self {
        case .spaceBugs: return "Clawd vs. a formation of bugs. Arrows and Space."
        case .bugHunt: return "Shoot the bugs out of the sky; the dog fetches. Aim and click."
        }
    }

    var symbol: String {
        switch self {
        case .spaceBugs: return "gamecontroller"
        case .bugHunt: return "scope"
        }
    }

    func make(defaults: UserDefaults = .standard) -> NSView & IslandGame {
        switch self {
        case .spaceBugs: return BreakGameView(defaults: defaults)
        case .bugHunt: return HuntGameView(defaults: defaults)
        }
    }

    static let size = NSSize(width: 432, height: 470)

    /// The game last started, listed first next time.
    static var last: GameChoice {
        get { UserDefaults.standard.string(forKey: "islandLastGame").flatMap(GameChoice.init) ?? .spaceBugs }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "islandLastGame") }
    }
}
